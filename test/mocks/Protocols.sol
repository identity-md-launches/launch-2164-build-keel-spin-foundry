// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFWAV2, IIntake} from "../../src/interfaces/IKeelProtocols.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

contract MockIMD is ERC20 {
    constructor() ERC20("Mock IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockNFT is ERC721 {
    bool public rejectTransfers;
    constructor() ERC721("Mock collection", "NFT") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function setRejectTransfers(bool reject) external {
        rejectTransfers = reject;
    }

    function transferFrom(address from, address to, uint256 id) public override {
        require(!rejectTransfers, "NFT transfer disabled");
        super.transferFrom(from, to, id);
    }
}

contract MockFloor {
    uint256 public price;
    uint48 public observedAt;
    bool public fails;

    function set(uint256 price_, uint256 observedAt_) external {
        price = price_;
        observedAt = uint48(observedAt_);
    }

    function setFails(bool fail) external {
        fails = fail;
    }

    function getFloor(address) external view returns (uint256, uint48) {
        require(!fails, "feed unavailable");
        return (price, observedAt);
    }
}

contract MockFWA is IFWAV2 {
    uint256 public fee = 0.1 ether;
    uint256 public vrf = 0.003 ether;
    uint256 public vrfGasUnits;
    uint256 public purchaseRebate;
    uint256 public settlementDiscountBps = 9000;
    uint256 public settlementWindow = 24 hours;
    uint256 public nextRequest;
    uint256 public nextListing;
    uint256 public lastMaxFee;
    uint256 public lastMinWeighted;
    uint256 public lastSlippage;
    address public lastBuilder;
    address public rewards;
    address public token;
    bool public blackout;
    bool public failAcquire;
    bool public failSettlement;
    mapping(uint256 => Acquisition) private _acquisitions;
    mapping(uint256 => Listing) private _listings;
    mapping(address => uint256) public acquisitionRefundCredit;
    mapping(uint256 => address) public stuckNFTRecipient;
    mapping(uint256 => address) public builder;

    function acquisitions(uint256 id) external view returns (Acquisition memory) {
        return _acquisitions[id];
    }

    function listings(uint256 id) external view returns (Listing memory) {
        return _listings[id];
    }

    function quoteAcquisitionPrice() external view returns (uint256, uint256, uint256) {
        uint256 liveVrf = vrf + vrfGasUnits * tx.gasprice;
        return (fee, liveVrf, fee + liveVrf);
    }

    function isPurchaseBlackout() external view returns (bool) {
        return blackout;
    }

    function setPrice(uint256 fee_, uint256 vrf_) external {
        fee = fee_;
        vrf = vrf_;
    }

    function setGasUnits(uint256 units) external {
        vrfGasUnits = units;
    }

    function setRebate(uint256 amount) external {
        purchaseRebate = amount;
    }

    function setDiscount(uint256 bps) external {
        settlementDiscountBps = bps;
    }

    function setWindow(uint256 window) external {
        settlementWindow = window;
    }

    function setBlackout(bool value) external {
        blackout = value;
    }

    function setFailures(bool acquire_, bool settle_) external {
        failAcquire = acquire_;
        failSettlement = settle_;
    }

    function setRewards(address rewards_, address token_) external {
        rewards = rewards_;
        token = token_;
    }

    function acquire(address purchaser, uint256 count, uint256 maxFee, uint256 weighted, uint256 slippage)
        external
        payable
        returns (uint256[] memory ids)
    {
        require(!failAcquire && !blackout, "acquisition disabled");
        require(count == 1 && purchaser != msg.sender && slippage <= 10000, "bad acquire args");
        uint256 actualFee = fee - purchaseRebate;
        require(maxFee >= actualFee && maxFee != 0, "fee guard");
        uint256 cost = actualFee + vrf + vrfGasUnits * tx.gasprice;
        require(msg.value >= cost, "payment");
        lastMaxFee = maxFee;
        lastMinWeighted = weighted;
        lastSlippage = slippage;
        lastBuilder = msg.sender;
        ids = new uint256[](1);
        ids[0] = ++nextRequest;
        builder[ids[0]] = msg.sender;
        _acquisitions[ids[0]] = Acquisition(purchaser, block.number, actualFee, 0, 1);
        if (msg.value > cost) _send(msg.sender, msg.value - cost);
    }

    function allocate(uint256 requestId, MockNFT nft, uint256 tokenId, uint256 backing, address depositor)
        external
        returns (uint256 listingId)
    {
        Acquisition storage a = _acquisitions[requestId];
        require(a.status == 1 || a.status == 5, "not pending");
        nft.mint(address(this), tokenId);
        listingId = ++nextListing;
        _listings[listingId] =
            Listing(address(nft), depositor, a.purchaser, tokenId, 1, backing, 0, 0, 0, uint64(block.timestamp), 2);
        a.listingId = listingId;
        a.status = 2;
    }

    function setStatus(uint256 requestId, uint8 status) external {
        _acquisitions[requestId].status = status;
    }

    function refund(uint256 requestId, bool expired) external {
        Acquisition storage a = _acquisitions[requestId];
        require(a.status == 1 || a.status == 5 || a.status == 6, "not pending");
        a.status = expired ? 3 : 4;
        acquisitionRefundCredit[a.purchaser] += a.priceEscrowed;
    }

    function withdrawAcquisitionRefund() external returns (uint256 amount) {
        amount = acquisitionRefundCredit[msg.sender];
        require(amount > 0, "no credit");
        delete acquisitionRefundCredit[msg.sender];
        _send(msg.sender, amount);
    }

    function keepNFT(uint256 id) external {
        Listing storage l = _listings[id];
        require(!failSettlement && l.status == 2 && msg.sender == l.purchaser, "not purchaser");
        l.status = 4;
        IERC721(l.collection).safeTransferFrom(address(this), l.purchaser, l.tokenId);
    }

    function acceptDepositorBid(uint256 id) external {
        Listing storage l = _listings[id];
        require(!failSettlement && l.status == 2 && msg.sender == l.purchaser, "not purchaser");
        _bid(id);
    }

    function depositorReclaimNFT(uint256 id) external {
        Listing storage l = _listings[id];
        require(
            l.status == 2 && msg.sender == l.depositor && block.timestamp >= l.allocatedAt + settlementWindow,
            "depositor deadline"
        );
        _bid(id);
    }

    function _bid(uint256 id) internal {
        Listing storage l = _listings[id];
        l.status = 4;
        _deliver(id, l.depositor);
        _send(l.purchaser, l.value * settlementDiscountBps / 10000);
    }

    function depositorReclaimBacking(uint256 id) external {
        Listing storage l = _listings[id];
        require(msg.sender == l.depositor && block.timestamp >= l.allocatedAt + settlementWindow, "depositor deadline");
        _finalize(id);
    }

    function finalizeUnsettled(uint256 id) external {
        require(block.timestamp >= _listings[id].allocatedAt + settlementWindow, "finalizer deadline");
        _finalize(id);
    }

    function _finalize(uint256 id) internal {
        Listing storage l = _listings[id];
        require(l.status == 2, "not allocated");
        l.status = 4;
        // The verified automatic-delivery path uses transferFrom, so no receiver hook is guaranteed.
        _deliver(id, l.purchaser);
    }

    function _deliver(uint256 id, address to) internal {
        Listing storage l = _listings[id];
        try IERC721(l.collection).transferFrom(address(this), to, l.tokenId) {}
        catch {
            stuckNFTRecipient[id] = to;
        }
    }

    function recoverStuckNFT(uint256 id) external {
        require(stuckNFTRecipient[id] == msg.sender, "not stuck recipient");
        delete stuckNFTRecipient[id];
        Listing storage l = _listings[id];
        IERC721(l.collection).transferFrom(address(this), msg.sender, l.tokenId);
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount, gas: 100000}("");
        require(ok, "ETH transfer");
    }
    receive() external payable {}
}

contract MockIntake is IIntake {
    uint256 public nonce;
    uint256 public price = 0.5 ether;
    bytes public lastBody;
    bytes32 public lastAction;
    bytes4 public lastFailure;
    address public lastAsset;
    uint256 public lastAmount;
    mapping(bytes32 => Callback) public callbacks;
    mapping(bytes32 => bytes4) public failures;

    function setPrice(uint256 amount) external {
        price = amount;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        require(msg.value == 0 && amount == price, "exact IMD payment");
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "token payment");
        id = keccak256(abi.encode(address(this), ++nonce));
        callbacks[id] = callback;
        failures[id] = onFailure;
        lastBody = body;
        lastAction = action;
        lastFailure = onFailure;
        lastAsset = asset;
        lastAmount = amount;
    }

    function result(bytes32 id, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        returns (bool)
    {
        Callback memory c = callbacks[id];
        (bool ok,) = c.target.call{gas: 200000}(abi.encodeWithSelector(c.selector, id, a, signature));
        return ok;
    }

    function fail(bytes32 id) external returns (bool) {
        Callback memory c = callbacks[id];
        (bool ok,) = c.target.call{gas: 200000}(
            abi.encodeWithSelector(failures[id], id, uint8(2), bytes32("disagreed"), uint16(2), uint16(5), bytes(""))
        );
        return ok;
    }
}

contract RejectNFT is IERC721Receiver {
    bool public reject = true;

    function setReject(bool value) external {
        reject = value;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(!reject, "team rejects NFT");
        return IERC721Receiver.onERC721Received.selector;
    }
    receive() external payable {}
}
