// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev ABI subsets checked against the mainnet Sourcify sources; static structs preserve tuple encoding.
interface IFWAV2 {
    struct Acquisition {
        address purchaser;
        uint256 requestBlock;
        uint256 priceEscrowed;
        uint256 listingId;
        uint8 status;
    }

    struct Listing {
        address collection;
        address depositor;
        address purchaser;
        uint256 tokenId;
        uint256 weight;
        uint256 value;
        uint256 feeShare;
        uint256 feeDebt;
        uint256 slot;
        uint64 allocatedAt;
        uint8 status;
    }
    function quoteAcquisitionPrice() external view returns (uint256 fee, uint256 vrf, uint256 total);
    function acquire(
        address purchaser,
        uint256 count,
        uint256 maxAcquisitionFee,
        uint256 minWeightedValue,
        uint256 maxNegativeSlippageBps
    ) external payable returns (uint256[] memory);
    function acquisitions(uint256 requestId) external view returns (Acquisition memory);
    function listings(uint256 listingId) external view returns (Listing memory);
    function settlementDiscountBps() external view returns (uint256);
    function settlementWindow() external view returns (uint256);
    function isPurchaseBlackout() external view returns (bool);
    function acquisitionRefundCredit(address purchaser) external view returns (uint256);
    function withdrawAcquisitionRefund() external returns (uint256);
    function keepNFT(uint256 listingId) external;
    function acceptDepositorBid(uint256 listingId) external;
    function stuckNFTRecipient(uint256 listingId) external view returns (address);
    function recoverStuckNFT(uint256 listingId) external;
    function rewards() external view returns (address);
    function token() external view returns (address);
}

interface ICollectionFloorOracle {
    function getFloor(address collection) external view returns (uint256 price, uint48 observedAt);
}

interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }
    function priceOf(bytes32 action, address asset) external view returns (uint256);
    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32);
}

interface IKeelVault {
    function teamWallet() external view returns (address);
    function unresolvedShares() external view returns (uint256);
}

interface IKeelRouter {
    function vault() external view returns (address);
    function pool() external view returns (address);
    function purchase(uint256 maxAcquisitionFee, uint256 minWeightedValue, uint256 maxNegativeSlippageBps)
        external
        payable
        returns (uint256);
    function buildOracleBody(address collection, uint256 tokenId, string[4] calldata definitions)
        external
        pure
        returns (bytes memory);
}

interface IFwaRewards {
    function claimAccruedTokens(uint256 minOut) external returns (uint256);
    function withdrawTokenBuyAllowanceAsETH() external returns (uint256);
    function token() external view returns (address);
    function fwa() external view returns (address);
}

interface IFwaToken {
    function balanceOf(address account) external view returns (uint256);
    function permit2() external view returns (address);
}

interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IFwaTransferHelper {
    function token() external view returns (address);
    function permit2() external view returns (address);
    function depositWithPermit2(
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature,
        address recipient
    ) external returns (uint256 totalPending);
}
