// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IFWAV2,
    IKeelVault,
    IFwaRewards,
    IFwaToken,
    IFwaTransferHelper,
    IPermit2
} from "./interfaces/IKeelProtocols.sol";
import {OracleBody} from "./OracleBody.sol";

/// @notice Single-vault builder router. Adapted from adamlizek/fwa-examples/FWAV2BuilderBase.sol.
/// @dev Constructor wiring is static. Reward dependency validation happens on use, not deployment.
contract KeelFwaRouter is Ownable, ReentrancyGuard {
    address public immutable vault;
    IFWAV2 public pool;
    IFwaTransferHelper public transferHelper;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 public nextTransferNonce;
    bytes32 private activePermitHash;

    error OnlyVault();
    error InvalidConfiguration();
    error NotConfigured();
    error OutstandingBets();
    error TransferFailed();
    error InvalidAmount();
    error DeadlineExpired();

    event PoolSet(address indexed pool);
    event TransferHelperSet(address indexed helper);
    event PurchaseForwarded(uint256 indexed requestId, uint256 payment, uint256 refund);
    event BuilderRewardsQueued(address indexed teamWallet, uint256 tokenOut, uint256 nonce, uint256 totalPending);
    event BuilderETHClaimed(address indexed teamWallet, uint256 amount);

    constructor(address owner_, address vault_, address pool_) Ownable(owner_) {
        if (vault_ == address(0) || pool_ == address(0)) revert InvalidConfiguration();
        vault = vault_;
        pool = IFWAV2(pool_);
        emit PoolSet(pool_);
    }

    function buildOracleBody(address collection, uint256 tokenId, string[4] calldata definitions)
        external
        pure
        returns (bytes memory)
    {
        return OracleBody.build(collection, tokenId, definitions);
    }

    function setPool(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidConfiguration();
        if (IKeelVault(vault).totalSharesOutstanding() != 0) revert OutstandingBets();
        pool = IFWAV2(to);
        emit PoolSet(to);
    }

    /// @notice Set the protocol's FWATokenTransfer helper published by FWA. No guessed launch address.
    function setTransferHelper(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidConfiguration();
        transferHelper = IFwaTransferHelper(to);
        emit TransferHelperSet(to);
    }

    function purchase(uint256 maxAcquisitionFee, uint256 minWeightedValue, uint256 maxNegativeSlippageBps)
        external
        payable
        nonReentrant
        returns (uint256 requestId)
    {
        if (msg.sender != vault) revert OnlyVault();
        uint256 beforeBalance = address(this).balance - msg.value;
        uint256[] memory ids =
            pool.acquire{value: msg.value}(vault, 1, maxAcquisitionFee, minWeightedValue, maxNegativeSlippageBps);
        if (ids.length != 1 || ids[0] == 0) revert InvalidConfiguration();
        requestId = ids[0];
        // Only this purchase's overpayment belongs to the round. Existing builder ETH is excluded.
        uint256 refund = address(this).balance - beforeBalance;
        if (refund != 0) {
            (bool ok,) = payable(vault).call{value: refund}("");
            if (!ok) revert TransferFailed();
        }
        emit PurchaseForwarded(requestId, msg.value, refund);
    }

    /// @notice Buy FWA with builder revenue and queue it for teamWallet through FWA's transfer helper.
    /// @dev FWA cannot be transferred directly between ordinary accounts. Anyone claims from the helper next block.
    function claimBuilderRewards(uint256 minFWAOut, uint256 deadline)
        external
        onlyOwner
        nonReentrant
        returns (uint256 tokenOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (minFWAOut == 0) revert InvalidAmount();
        if (address(transferHelper) == address(0)) revert NotConfigured();
        IFwaRewards rewards = IFwaRewards(pool.rewards());
        address token = rewards.token();
        _checkRewardWiring(rewards, token);
        uint256 beforeBalance = IFwaToken(token).balanceOf(address(this));
        tokenOut = rewards.claimAccruedTokens(minFWAOut);
        if (tokenOut < minFWAOut || IFwaToken(token).balanceOf(address(this)) - beforeBalance != tokenOut) {
            revert InvalidAmount();
        }
        _queue(token, tokenOut, deadline);
    }

    function queueHeldBuilderRewards(uint256 amount, uint256 deadline) external onlyOwner nonReentrant {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (address(transferHelper) == address(0)) revert NotConfigured();
        IFwaRewards rewards = IFwaRewards(pool.rewards());
        address token = rewards.token();
        _checkRewardWiring(rewards, token);
        if (amount == 0 || amount > IFwaToken(token).balanceOf(address(this))) revert InvalidAmount();
        _queue(token, amount, deadline);
    }

    function _checkRewardWiring(IFwaRewards rewards, address token) internal view {
        if (
            rewards.fwa() != address(pool) || token != pool.token() || transferHelper.token() != token
                || IFwaToken(token).permit2() != PERMIT2 || transferHelper.permit2() != PERMIT2
        ) revert InvalidConfiguration();
    }

    function _queue(address token, uint256 amount, uint256 deadline) internal {
        address recipient = IKeelVault(vault).teamWallet();
        if (recipient == address(this) || recipient == address(transferHelper) || recipient == address(0)) {
            revert InvalidConfiguration();
        }
        uint256 nonce = nextTransferNonce++;
        IPermit2.PermitTransferFrom memory permit =
            IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(token, amount), nonce, deadline);
        bytes32 permissionsHash =
            keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), token, amount));
        bytes32 permitHash = keccak256(
            abi.encode(
                keccak256(
                    "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
                ),
                permissionsHash,
                address(transferHelper),
                nonce,
                deadline
            )
        );
        activePermitHash = keccak256(abi.encodePacked("\x19\x01", IPermit2(PERMIT2).DOMAIN_SEPARATOR(), permitHash));
        uint256 pending = transferHelper.depositWithPermit2(permit, "", recipient);
        delete activePermitHash;
        emit BuilderRewardsQueued(recipient, amount, nonce, pending);
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        return msg.sender == PERMIT2 && signature.length == 0 && activePermitHash != 0 && hash == activePermitHash
            ? bytes4(0x1626ba7e)
            : bytes4(0xffffffff);
    }

    /// @notice Only succeeds in the protocol's emergency mode. No vault funds enter this path.
    function recoverBuilderAllowanceAsETH() external onlyOwner nonReentrant returns (uint256 amount) {
        uint256 beforeBalance = address(this).balance;
        IFwaRewards(pool.rewards()).withdrawTokenBuyAllowanceAsETH();
        amount = address(this).balance - beforeBalance;
        _payTeam(amount);
    }

    function withdrawBuilderETH() external onlyOwner nonReentrant {
        _payTeam(address(this).balance);
    }

    function _payTeam(uint256 amount) internal {
        address recipient = IKeelVault(vault).teamWallet();
        (bool ok,) = payable(recipient).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit BuilderETHClaimed(recipient, amount);
    }

    receive() external payable {}
}
