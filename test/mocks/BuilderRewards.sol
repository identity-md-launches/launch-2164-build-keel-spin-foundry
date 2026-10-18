// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IPermit2, IFwaTransferHelper} from "../../src/interfaces/IKeelProtocols.sol";

contract LockedFWA is ERC20 {
    address public constant permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    mapping(address => bool) public distributors;
    constructor() ERC20("Locked FWA mock", "FWA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setDistributor(address who, bool value) external {
        distributors[who] = value;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return spender == permit2 ? type(uint256).max : super.allowance(owner, spender);
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(from == address(0) || to == address(0) || distributors[from] || distributors[to], "FWA transfer locked");
        super._update(from, to, amount);
    }
}

contract MockRewards {
    address public token;
    address public fwa;
    mapping(address => uint256) public tokenBuyAllowance;
    bool public emergency;

    constructor(address token_, address pool_) {
        token = token_;
        fwa = pool_;
    }

    function credit(address builder, uint256 amount) external {
        tokenBuyAllowance[builder] += amount;
    }

    function setEmergency(bool value) external {
        emergency = value;
    }

    function claimAccruedTokens(uint256 minOut) external returns (uint256 out) {
        out = tokenBuyAllowance[msg.sender] * 1000;
        require(out >= minOut, "minimum output");
        delete tokenBuyAllowance[msg.sender];
        LockedFWA(token).mint(msg.sender, out);
    }

    function withdrawTokenBuyAllowanceAsETH() external returns (uint256 amount) {
        require(emergency, "core not in emergency");
        amount = tokenBuyAllowance[msg.sender];
        delete tokenBuyAllowance[msg.sender];
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "payment");
    }
    receive() external payable {}
}

contract MockPermit2 {
    mapping(address => mapping(uint256 => bool)) public used;

    function DOMAIN_SEPARATOR() public pure returns (bytes32) {
        return keccak256("test Permit2 domain");
    }

    function transfer(IPermit2.PermitTransferFrom calldata permit, address owner, bytes calldata signature) external {
        require(block.timestamp <= permit.deadline && !used[owner][permit.nonce], "permit expired or used");
        bytes32 permissionsHash = keccak256(
            abi.encode(
                keccak256("TokenPermissions(address token,uint256 amount)"),
                permit.permitted.token,
                permit.permitted.amount
            )
        );
        bytes32 hash = keccak256(
            abi.encode(
                keccak256(
                    "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
                ),
                permissionsHash,
                msg.sender,
                permit.nonce,
                permit.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), hash));
        require(IERC1271(owner).isValidSignature(digest, signature) == 0x1626ba7e, "bad scoped signature");
        used[owner][permit.nonce] = true;
        require(IERC20(permit.permitted.token).transferFrom(owner, msg.sender, permit.permitted.amount), "transfer");
    }
}

contract MockTransferHelper is IFwaTransferHelper {
    address public token;
    address public constant permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bool public enabled = true;
    mapping(address => uint256) public claimable;
    mapping(address => uint256) public depositedBlock;

    constructor(address token_) {
        token = token_;
    }

    function setEnabled(bool value) external {
        enabled = value;
    }

    function depositWithPermit2(
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature,
        address recipient
    ) external returns (uint256 totalPending) {
        require(enabled && permit.permitted.token == token, "helper disabled or wrong token");
        MockPermit2(permit2).transfer(permit, msg.sender, signature);
        claimable[recipient] += permit.permitted.amount;
        depositedBlock[recipient] = block.number;
        return claimable[recipient];
    }

    function claim(address recipient) external {
        require(block.number > depositedBlock[recipient], "next block");
        uint256 amount = claimable[recipient];
        delete claimable[recipient];
        require(IERC20(token).transfer(recipient, amount), "payment");
    }
}
