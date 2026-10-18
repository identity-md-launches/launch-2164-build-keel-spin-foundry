// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {OracleBody} from "./OracleBody.sol";
import {IFWAV2, ICollectionFloorOracle, IIntake, IKeelRouter} from "./interfaces/IKeelProtocols.sol";

/// @title Keel Spin: pooled ETH purchases and off-chain NFT sale proceeds.
/// @notice Only one FWA request may be unresolved, because its ETH transfers contain no request id.
/// @dev No sweep of ETH exists. All cash reserves and fee liabilities are tracked in accountedETH.
contract KeelSpinVault is Ownable, ReentrancyGuard, OracleAttestationConsumer, IERC721Receiver {
    using SafeERC20 for IERC20;

    enum State {
        None,
        Open,
        Spinning,
        Allocated,
        OraclePending,
        DecisionReady,
        AwaitingSale,
        Settled
    }
    enum DecisionPath {
        None,
        ObviousFloor,
        Oracle,
        FallbackFloor,
        FallbackDefault,
        External
    }

    struct Round {
        State state;
        uint16 bettors;
        uint16 fee;
        bool nftForwarded;
        bool oracleFailed;
        bool kept;
        address feeRecipient;
        address pool;
        address collection;
        uint64 allocatedAt;
        uint64 requestedAt;
        uint64 answerExpiresAt;
        uint256 totalShares;
        uint256 cash;
        uint256 requestId;
        uint256 listingId;
        uint256 tokenId;
        uint256 backing;
        uint256 ethBid;
        uint256 netOffer;
        bytes32 oracleRequestId;
        DecisionPath path;
    }

    mapping(uint256 => Round) private _rounds;
    mapping(uint256 => mapping(address => uint256)) public stake;
    mapping(bytes32 => uint256) public pending;
    mapping(bytes32 => uint256) private nftRound;
    mapping(address => uint256) public feeCredit;
    uint256 public currentRoundId;
    uint256 public roundCount;
    uint256 public activeRoundId;
    uint256 public totalSharesOutstanding;
    /// @notice Shares of rounds that still depend on the FWA/router wiring: Open or unresolved. Settled and
    /// AwaitingSale rounds only hold cash, so their unclaimed shares never block a migration.
    uint256 public unresolvedShares;
    uint256 public accountedETH;

    IFWAV2 public fwa;
    IKeelRouter public router;
    ICollectionFloorOracle public floorOracle;
    IIntake public intake;
    IERC20 public imd;
    address public teamWallet;
    bool public betsPaused;

    uint256 public minBet = 0.001 ether;
    uint16 public maxBettors = 500;
    uint16 public bufferBps = 500;
    uint256 public spinReward = 0.002 ether;
    uint256 public maxSpinGasPrice = 100 gwei;
    uint256 public minWeightedValue;
    uint16 public maxNegativeSlippageBps = 500;
    uint16 public feeBps;
    uint16 public haircutBps = 1500;
    uint16 public marginBps = 500;
    uint256 public maxFloorAge = 24 hours;
    // The live FWAV2 settlementWindow is one hour, so the three timing settings must sum to less than that:
    // decisionDeadline = allocatedAt + 50 min, fallbackAt = allocatedAt + 30 min, last paid ask at +20 min.
    uint256 public safetyMargin = 10 minutes;
    uint256 public fallbackLead = 20 minutes;
    uint256 public minOracleLead = 10 minutes;
    bool public defaultKeep = true;
    bytes32 public oracleAction = bytes32("oracle.request@oracle-1");
    uint256 public oraclePrice = 0.5 ether;
    uint256 public lowImdThreshold = 2 ether;
    string[4] public definitions;

    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_OFFER = 1e22;
    uint256 private constant MAX_ROUNDS_PER_BET = 32;
    /// @dev After this long past allocation, a kept NFT the collection refuses to release no longer blocks the
    /// round's cash: the team may settle the round, and the NFT stays forwardable whenever it becomes movable.
    uint256 internal constant STRANDED_NFT_GRACE = 30 days;

    error InvalidAddress();
    error InvalidParameter();
    error WrongState();
    error Paused();
    error NotConfigured();
    error OutstandingBets();
    error SpinInProgress();
    error InsufficientRoundBalance();
    error GasPriceTooHigh();
    error Blackout();
    error TooManyRounds();
    error InvalidAmount();
    error TransferFailed();
    error NotIntake();
    error UnknownRequest();
    error InvalidAttestation();
    error TooEarly();
    error StaleAnswer();
    error NotSaleOperator();
    error UnexpectedNFT();

    event RoundStateChanged(uint256 indexed roundId, State state);
    event BetPlaced(uint256 indexed roundId, address indexed bettor, uint256 amount, uint256 shares);
    event Withdrawn(
        uint256 indexed roundId, address indexed bettor, address indexed recipient, uint256 amount, uint256 shares
    );
    event SpinRequested(
        uint256 indexed roundId,
        uint256 indexed requestId,
        address indexed caller,
        uint256 quote,
        uint256 reward,
        uint256 refund
    );
    event AllocationRecorded(
        uint256 indexed roundId, uint256 indexed listingId, address collection, uint256 tokenId, uint256 deadline
    );
    event AcquisitionRefunded(
        uint256 indexed roundId, uint256 indexed requestId, uint256 refund, uint256 remainingCash
    );
    event OracleRequested(uint256 indexed roundId, bytes32 indexed requestId);
    event OracleValueStored(uint256 indexed roundId, bytes32 indexed requestId, uint256 netOffer, uint64 expiresAt);
    event OracleFailed(uint256 indexed roundId, bytes32 indexed requestId, uint8 status, bytes32 reason);
    event OracleRequestCleared(uint256 indexed roundId, bytes32 indexed requestId);
    event LowImdBalance(uint256 balance);
    event Decision(
        uint256 indexed roundId,
        address indexed collection,
        uint256 indexed tokenId,
        uint256 ethBid,
        uint256 netOffer,
        bool keep,
        DecisionPath path
    );
    event NFTForwarded(uint256 indexed roundId, address indexed recipient);
    event NFTForwardPending(uint256 indexed roundId);
    event StuckNFTRecovered(uint256 indexed roundId);
    event SaleProceeds(uint256 indexed roundId, bytes32 indexed saleTxHash, uint256 amount);
    event RoundSettled(uint256 indexed roundId, uint256 distributable, uint256 fee);
    event Claimed(uint256 indexed roundId, address indexed bettor, address indexed recipient, uint256 amount);
    event FeesClaimed(address indexed beneficiary, address indexed recipient, uint256 amount);
    event AddressSet(bytes32 indexed parameter, address value);
    event ParameterSet(bytes32 indexed parameter, uint256 value);
    event BetParametersSet(uint256 minBet, uint16 maxBettors, uint16 bufferBps);
    event SpinParametersSet(
        uint256 spinReward, uint256 maxSpinGasPrice, uint256 minWeightedValue, uint16 maxNegativeSlippageBps
    );
    event DecisionParametersSet(
        uint16 haircutBps,
        uint16 marginBps,
        uint256 maxFloorAge,
        uint256 safetyMargin,
        uint256 fallbackLead,
        uint256 minOracleLead,
        bool defaultKeep
    );
    event DefinitionSet(uint256 indexed index, string value);
    event OraclePaymentSet(bytes32 action, uint256 price, uint256 lowBalanceThreshold);
    event ImdWithdrawn(address indexed recipient, uint256 amount);

    constructor(
        address owner_,
        address fwa_,
        address floorOracle_,
        address intake_,
        address imd_,
        address signer_,
        address teamWallet_
    ) Ownable(owner_) OracleAttestationConsumer(signer_) {
        _checkAddress(fwa_);
        _checkAddress(floorOracle_);
        _checkAddress(intake_);
        _checkAddress(imd_);
        _checkAddress(teamWallet_);
        fwa = IFWAV2(fwa_);
        floorOracle = ICollectionFloorOracle(floorOracle_);
        intake = IIntake(intake_);
        imd = IERC20(imd_);
        teamWallet = teamWallet_;
        definitions[0] =
        "Best token, collection or matching trait offer. WETH counts. Ignore offers expiring within 2 hours.";
        definitions[1] =
            "OpenSea, Blur, and for CryptoPunks or wrappers the native market 0xb47e3cd837ddf8e4c57f05d70ab865de6e193bbb.";
        definitions[2] = "What the seller actually receives after that marketplace's fee and enforced creator royalty.";
        definitions[3] = "Never invent offers. Answer 0 if no qualifying live offer exists.";
        _newRound();
    }

    function rounds(uint256 id) external view returns (Round memory) {
        return _rounds[id];
    }

    /// @notice The keeper reward is clamped against the current total quote, including its VRF fee.
    function effectiveSpinReward(uint256 quote) public view returns (uint256) {
        return Math.min(spinReward, quote / 50);
    }

    /// @dev Call with the intended transaction gas price: FWA's VRF quote uses tx.gasprice.
    function liveTarget() public view returns (uint256) {
        (,, uint256 total) = fwa.quoteAcquisitionPrice();
        if (total == 0) revert InvalidAmount();
        return Math.mulDiv(total, BPS + bufferBps, BPS) + effectiveSpinReward(total);
    }

    function bet() external payable nonReentrant {
        _bet(currentRoundId);
    }

    /// @notice Tops up any Open round, including an older round left underfunded by a price rise/refund.
    function betInto(uint256 id) external payable nonReentrant {
        _bet(id);
    }

    function _bet(uint256 id) internal {
        if (betsPaused) revert Paused();
        if (address(router) == address(0)) revert NotConfigured();
        if (msg.value < minBet) revert InvalidAmount();
        if (_rounds[id].state != State.Open) revert WrongState();
        uint256 target = liveTarget();
        uint256 remaining = msg.value;
        for (uint256 i; remaining != 0; ++i) {
            if (i == MAX_ROUNDS_PER_BET) revert TooManyRounds();
            Round storage r = _rounds[id];
            if (r.state != State.Open || r.cash >= target || (stake[id][msg.sender] == 0 && r.bettors >= maxBettors)) {
                id = _nextDepositRound(id);
                continue;
            }
            uint256 amount = Math.min(remaining, target - r.cash);
            // Shares retain losses after refunds. New entrants buy at the reduced cash/share price.
            uint256 shares = r.totalShares == 0 ? amount : Math.mulDiv(amount, r.totalShares, r.cash);
            if (shares == 0) revert InvalidAmount();
            if (stake[id][msg.sender] == 0) ++r.bettors;
            stake[id][msg.sender] += shares;
            r.totalShares += shares;
            totalSharesOutstanding += shares;
            unresolvedShares += shares;
            _credit(r, amount);
            remaining -= amount;
            emit BetPlaced(id, msg.sender, amount, shares);
            if (remaining != 0) id = _nextDepositRound(id);
        }
    }

    function _nextDepositRound(uint256 id) internal returns (uint256) {
        if (id != currentRoundId && _rounds[currentRoundId].state == State.Open) return currentRoundId;
        return _newRound();
    }

    function _newRound() internal returns (uint256 id) {
        id = ++roundCount;
        currentRoundId = id;
        Round storage r = _rounds[id];
        r.fee = feeBps;
        r.feeRecipient = teamWallet;
        _state(id, State.Open);
    }

    function withdraw(uint256 id) external nonReentrant {
        _withdraw(id, payable(msg.sender));
    }

    function withdrawTo(uint256 id, address payable recipient) external nonReentrant {
        _withdraw(id, recipient);
    }

    function _withdraw(uint256 id, address payable recipient) internal {
        _checkAddress(recipient);
        Round storage r = _rounds[id];
        if (r.state != State.Open) revert WrongState();
        (uint256 amount, uint256 shares) = _burn(id, msg.sender);
        --r.bettors;
        emit Withdrawn(id, msg.sender, recipient, amount, shares);
        _send(recipient, amount);
    }

    function spin(uint256 id) external nonReentrant {
        Round storage r = _rounds[id];
        if (r.state != State.Open || r.totalShares == 0) revert WrongState();
        if (activeRoundId != 0) revert SpinInProgress();
        if (address(router) == address(0)) revert NotConfigured();
        if (router.vault() != address(this) || router.pool() != address(fwa)) revert InvalidParameter();
        if (tx.gasprice > maxSpinGasPrice) revert GasPriceTooHigh();
        if (block.timestamp % 12 hours >= 11 hours + 45 minutes || fwa.isPurchaseBlackout()) revert Blackout();
        (uint256 fee, uint256 vrf, uint256 total) = fwa.quoteAcquisitionPrice();
        if (fee == 0 || total != fee + vrf) revert InvalidParameter();
        uint256 reward = effectiveSpinReward(total);
        if (r.cash < total + reward) revert InsufficientRoundBalance();
        r.pool = address(fwa);
        // Open rounds have never reached a decision; refunded attempts have only been Spinning.
        activeRoundId = id;
        _state(id, State.Spinning);
        r.cash -= total + reward;
        accountedETH -= total + reward;
        uint256 beforeBalance = address(this).balance;
        r.requestId = router.purchase{value: total}(fee, minWeightedValue, maxNegativeSlippageBps);
        uint256 refund = address(this).balance + total - beforeBalance;
        _credit(r, refund);
        _send(payable(msg.sender), reward);
        emit SpinRequested(id, r.requestId, msg.sender, total, reward, refund);
        if (currentRoundId == id) _newRound();
    }

    /// @notice Reconcile allocation, refunds, or a depositor/finalizer resolution. Processing VRF remains FWA's job.
    function syncRound(uint256 id) external nonReentrant {
        _sync(id);
        if (_rounds[id].state == State.AwaitingSale) _forward(id);
    }

    function _sync(uint256 id) internal {
        Round storage r = _rounds[id];
        // A resolved round has nothing left to reconcile; callers may still retry the NFT forward.
        if (r.state == State.AwaitingSale || r.state == State.Settled) return;
        if (activeRoundId != id || id == 0) revert WrongState();
        IFWAV2 pool = IFWAV2(r.pool);
        IFWAV2.Acquisition memory a = pool.acquisitions(r.requestId);
        if (a.purchaser != address(this)) revert InvalidParameter();
        if (a.status == 3 || a.status == 4) {
            if (r.state != State.Spinning) revert WrongState();
            uint256 beforeBalance = address(this).balance;
            pool.withdrawAcquisitionRefund();
            uint256 refund = address(this).balance - beforeBalance;
            _credit(r, refund);
            activeRoundId = 0;
            _state(id, State.Open);
            emit AcquisitionRefunded(id, r.requestId, refund, r.cash);
            return;
        }
        if (a.status != 2) return; // Pending, Ready or TimedOut needs the protocol's ordered processor.
        IFWAV2.Listing memory listing = pool.listings(a.listingId);
        if (listing.purchaser != address(this) || listing.value > type(uint128).max) revert InvalidParameter();
        if (r.listingId == 0) {
            r.listingId = a.listingId;
            r.collection = listing.collection;
            r.tokenId = listing.tokenId;
            r.backing = listing.value;
            r.allocatedAt = listing.allocatedAt;
            nftRound[keccak256(abi.encode(listing.collection, listing.tokenId))] = id;
            _state(id, State.Allocated);
            emit AllocationRecorded(id, a.listingId, listing.collection, listing.tokenId, decisionDeadline(id));
        }
        if (listing.status == 4) _reconcileOutcome(id);
        else if (listing.status != 2) revert WrongState();
    }

    function decisionDeadline(uint256 id) public view returns (uint256) {
        Round storage r = _rounds[id];
        if (r.allocatedAt == 0) return 0;
        uint256 window = IFWAV2(r.pool).settlementWindow();
        return uint256(r.allocatedAt) + (window > safetyMargin ? window - safetyMargin : 0);
    }

    function fallbackAt(uint256 id) public view returns (uint256) {
        uint256 deadline = decisionDeadline(id);
        uint256 allocatedAt = _rounds[id].allocatedAt;
        return deadline > allocatedAt + fallbackLead ? deadline - fallbackLead : allocatedAt;
    }

    function ethBid(uint256 id) public view returns (uint256) {
        Round storage r = _rounds[id];
        uint256 discount = IFWAV2(r.pool).settlementDiscountBps();
        if (discount > BPS) revert InvalidParameter();
        return Math.mulDiv(r.backing, discount, BPS);
    }

    function freshFloor(address collection) public view returns (bool available, uint256 price) {
        try floorOracle.getFloor(collection) returns (uint256 floor, uint48 timestamp) {
            if (
                floor != 0 && floor <= type(uint128).max && timestamp != 0 && timestamp <= block.timestamp
                    && block.timestamp - timestamp <= maxFloorAge
            ) return (true, floor);
        } catch {}
    }

    function oracleBody(uint256 id) public view returns (bytes memory) {
        Round storage r = _rounds[id];
        if (r.collection == address(0)) revert WrongState();
        return router.buildOracleBody(r.collection, r.tokenId, definitions);
    }

    function requestDecision(uint256 id) external nonReentrant {
        _sync(id);
        Round storage r = _rounds[id];
        if (r.state == State.AwaitingSale) {
            _forward(id);
            return;
        }
        if (r.state == State.Settled || r.state == State.Open) return;
        if (r.state != State.Allocated) revert WrongState();
        uint256 bid = ethBid(id);
        (bool available, uint256 floor) = freshFloor(r.collection);
        if (available && Math.mulDiv(floor, BPS - haircutBps, BPS) >= bid * 3) {
            _resolve(id, true, DecisionPath.ObviousFloor);
            return;
        }
        // A paid answer arrives minutes later and is refused from fallbackAt on (onOracleResult uses >=), so only
        // pay while strictly more than minOracleLead seconds remain; with a zero lead both checks then agree.
        if (r.oracleFailed || block.timestamp + minOracleLead >= fallbackAt(id)) {
            _fallback(id);
            return;
        }
        uint256 balance = imdBalance();
        if (balance < lowImdThreshold) emit LowImdBalance(balance);
        // Keep this path permissionless and live when the IMD treasury is empty; no repeat paid asks.
        if (balance < oraclePrice) return;
        if (intake.priceOf(oracleAction, address(imd)) != oraclePrice) revert InvalidParameter();
        r.requestedAt = uint64(block.timestamp);
        _state(id, State.OraclePending);
        imd.forceApprove(address(intake), oraclePrice);
        bytes32 requestId = intake.requestWithFailure(
            oracleAction,
            oracleBody(id),
            IIntake.Callback(address(this), this.onOracleResult.selector),
            this.onFailure.selector,
            address(imd),
            oraclePrice
        );
        imd.forceApprove(address(intake), 0);
        if (requestId == 0 || pending[requestId] != 0) revert InvalidParameter();
        r.oracleRequestId = requestId;
        pending[requestId] = id;
        emit OracleRequested(id, requestId);
        balance = imdBalance();
        if (balance < lowImdThreshold) emit LowImdBalance(balance);
    }

    /// @notice Bounded callback: verifies and stores only. NFT transfers/ETH settlement happen in executeDecision.
    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
    {
        if (msg.sender != address(intake)) revert NotIntake();
        uint256 id = pending[requestId];
        if (id == 0) revert UnknownRequest();
        Round storage r = _rounds[id];
        // A late delivery cannot revoke the fallback right once the missing-value cutoff has passed.
        if (r.state != State.OraclePending || block.timestamp >= fallbackAt(id)) revert StaleAnswer();
        if (
            a.chainId != 1 || a.answer.length != 32 || a.panelSize < 5 || a.quorum < 4 || a.agreed < a.quorum
                || a.agreed > a.panelSize || a.quorum > a.panelSize || a.issuedAt + uint256(5 minutes) < r.requestedAt
                || uint256(a.issuedAt) + 1 hours < block.timestamp || a.expiresAt < a.issuedAt
                || uint256(a.expiresAt) > uint256(a.issuedAt) + 1 hours
        ) revert InvalidAttestation();
        _verifyAttestation(a, signature);
        uint256 offer = decodeUint256(a);
        if (offer > MAX_OFFER) revert InvalidAttestation();
        _consume(a.requestId);
        delete pending[requestId];
        r.netOffer = offer;
        r.answerExpiresAt = a.expiresAt;
        _state(id, State.DecisionReady);
        emit OracleValueStored(id, requestId, offer, a.expiresAt);
    }

    function onFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata) external {
        if (msg.sender != address(intake)) revert NotIntake();
        uint256 id = pending[requestId];
        if (id == 0) revert UnknownRequest();
        Round storage r = _rounds[id];
        if (r.state != State.OraclePending) revert WrongState();
        delete pending[requestId];
        r.oracleFailed = true;
        _state(id, State.Allocated);
        emit OracleFailed(id, requestId, status, reason);
    }

    function executeDecision(uint256 id) external nonReentrant {
        _sync(id);
        Round storage r = _rounds[id];
        if (r.state == State.AwaitingSale) {
            _forward(id);
            return;
        }
        if (r.state == State.Settled || r.state == State.Open) return;
        if (!_validValue(r) || block.timestamp >= decisionDeadline(id)) revert StaleAnswer();
        _resolve(id, r.netOffer * BPS > ethBid(id) * (BPS + marginBps), DecisionPath.Oracle);
    }

    function settleFallback(uint256 id) external nonReentrant {
        _sync(id);
        Round storage r = _rounds[id];
        if (r.state == State.AwaitingSale) {
            _forward(id);
            return;
        }
        if (r.state == State.Settled || r.state == State.Open) return;
        if (r.state != State.Allocated && r.state != State.OraclePending && r.state != State.DecisionReady) {
            revert WrongState();
        }
        if (
            !r.oracleFailed && block.timestamp < decisionDeadline(id)
                && (block.timestamp < fallbackAt(id) || _validValue(r))
        ) revert TooEarly();
        _fallback(id);
    }

    function _validValue(Round storage r) internal view returns (bool) {
        return r.state == State.DecisionReady && block.timestamp <= r.answerExpiresAt;
    }

    function _fallback(uint256 id) internal {
        (bool available, uint256 floor) = freshFloor(_rounds[id].collection);
        bool keep = available
            ? Math.mulDiv(floor, BPS - haircutBps, BPS) > Math.mulDiv(ethBid(id), BPS + marginBps, BPS)
            : defaultKeep;
        _resolve(id, keep, available ? DecisionPath.FallbackFloor : DecisionPath.FallbackDefault);
    }

    function _resolve(uint256 id, bool keep, DecisionPath path) internal {
        Round storage r = _rounds[id];
        r.ethBid = ethBid(id); // live rate, including any change since the paid question
        r.path = path;
        _clearOracle(id);
        if (keep) IFWAV2(r.pool).keepNFT(r.listingId);
        else IFWAV2(r.pool).acceptDepositorBid(r.listingId);
        _reconcileOutcome(id);
        if (r.state == State.AwaitingSale) _forward(id);
    }

    function _reconcileOutcome(uint256 id) internal {
        Round storage r = _rounds[id];
        if (IFWAV2(r.pool).listings(r.listingId).status != 4) revert WrongState();
        bool keep = _ownsNFT(r) || IFWAV2(r.pool).stuckNFTRecipient(r.listingId) == address(this);
        if (r.path == DecisionPath.None) {
            r.path = DecisionPath.External;
            r.ethBid = ethBid(id);
        }
        _clearOracle(id);
        activeRoundId = 0;
        unresolvedShares -= r.totalShares;
        r.kept = keep;
        // A forced ETH transfer bypasses receive(). Reconcile actual cash after observing terminal FWA state.
        // Any unsolicited ETH also accrues to this resolving round; it cannot be swept by the owner.
        uint256 arrived = address(this).balance - accountedETH;
        _credit(r, arrived);
        emit Decision(id, r.collection, r.tokenId, r.ethBid, r.netOffer, keep, r.path);
        if (keep) _state(id, State.AwaitingSale);
        else _settle(id, Math.min(arrived, r.ethBid)); // the fee base is the bid, never a donation
    }

    function _clearOracle(uint256 id) internal {
        bytes32 requestId = _rounds[id].oracleRequestId;
        if (pending[requestId] != 0) {
            delete pending[requestId];
            emit OracleRequestCleared(id, requestId);
        }
    }

    function _ownsNFT(Round storage r) internal view returns (bool) {
        try IERC721(r.collection).ownerOf(r.tokenId) returns (address holder) {
            return holder == address(this);
        } catch {
            return false;
        }
    }

    /// @dev Accept only the allocated token, including before a keeper has called syncRound.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external view returns (bytes4) {
        uint256 id = nftRound[keccak256(abi.encode(msg.sender, tokenId))];
        if (id != 0) {
            if (from != _rounds[id].pool) revert UnexpectedNFT();
        } else {
            id = activeRoundId;
            if (id == 0 || from != _rounds[id].pool) revert UnexpectedNFT();
            IFWAV2 pool = IFWAV2(from);
            IFWAV2.Acquisition memory a = pool.acquisitions(_rounds[id].requestId);
            IFWAV2.Listing memory listing = pool.listings(a.listingId);
            if (
                a.status != 2 || listing.purchaser != address(this) || listing.collection != msg.sender
                    || listing.tokenId != tokenId
            ) revert UnexpectedNFT();
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    function forwardNFT(uint256 id) external nonReentrant {
        Round storage r = _rounds[id];
        if (r.state != State.AwaitingSale && !(r.state == State.Settled && r.kept)) revert WrongState();
        _forward(id);
    }

    /// @notice True once a kept NFT has stayed unforwardable for STRANDED_NFT_GRACE after allocation.
    function nftStranded(uint256 id) public view returns (bool) {
        Round storage r = _rounds[id];
        return r.kept && !r.nftForwarded && block.timestamp >= uint256(r.allocatedAt) + STRANDED_NFT_GRACE;
    }

    function _forward(uint256 id) internal {
        Round storage r = _rounds[id];
        if (r.nftForwarded) return;
        if (!_ownsNFT(r)) {
            emit NFTForwardPending(id);
            return;
        }
        r.nftForwarded = true;
        // Bounded call means a rejecting/gas-consuming team receiver never rolls back keeping the NFT.
        try IERC721(r.collection).safeTransferFrom{gas: 200_000}(address(this), teamWallet, r.tokenId) {
            emit NFTForwarded(id, teamWallet);
        } catch {
            r.nftForwarded = false;
            emit NFTForwardPending(id);
        }
    }

    /// @notice Pull a kept NFT that FWA could not deliver. Only the vault may call the pool for it, so this stays
    /// open after a stranded settlement (Settled && kept): the token must never be locked in the pool for good.
    function recoverStuckNFT(uint256 id) external nonReentrant {
        Round storage r = _rounds[id];
        if (activeRoundId == id) _sync(id);
        if (r.state != State.AwaitingSale && !(r.state == State.Settled && r.kept)) revert WrongState();
        IFWAV2(r.pool).recoverStuckNFT(r.listingId);
        emit StuckNFTRecovered(id);
        _forward(id);
    }

    function depositSaleProceeds(uint256 id, bytes32 saleTxHash) external payable nonReentrant {
        if (msg.sender != teamWallet && msg.sender != owner()) revert NotSaleOperator();
        Round storage r = _rounds[id];
        if (r.state != State.AwaitingSale || !(r.nftForwarded || nftStranded(id))) revert WrongState();
        if (msg.value == 0 || saleTxHash == 0) revert InvalidAmount();
        _credit(r, msg.value);
        emit SaleProceeds(id, saleTxHash, msg.value);
        _settle(id, msg.value);
    }

    function _settle(uint256 id, uint256 proceeds) internal {
        Round storage r = _rounds[id];
        uint256 fee = Math.mulDiv(proceeds, r.fee, BPS);
        r.cash -= fee;
        feeCredit[r.feeRecipient] += fee;
        // Fees stay accounted until pulled. Buffers and returned acquisition fees are never taxed.
        _state(id, State.Settled);
        emit RoundSettled(id, r.cash, fee);
    }

    function claimable(uint256 id, address bettor) public view returns (uint256) {
        Round storage r = _rounds[id];
        if (r.state != State.Settled || r.totalShares == 0) return 0;
        return Math.mulDiv(r.cash, stake[id][bettor], r.totalShares);
    }

    function withdrawable(uint256 id, address bettor) external view returns (uint256) {
        Round storage r = _rounds[id];
        if (r.state != State.Open || r.totalShares == 0) return 0;
        return Math.mulDiv(r.cash, stake[id][bettor], r.totalShares);
    }

    function claim(uint256 id) external nonReentrant {
        _claim(id, payable(msg.sender));
    }

    function claimTo(uint256 id, address payable recipient) external nonReentrant {
        _claim(id, recipient);
    }

    function _claim(uint256 id, address payable recipient) internal {
        _checkAddress(recipient);
        if (_rounds[id].state != State.Settled) revert WrongState();
        (uint256 amount,) = _burn(id, msg.sender);
        emit Claimed(id, msg.sender, recipient, amount);
        _send(recipient, amount);
    }

    function _burn(uint256 id, address bettor) internal returns (uint256 amount, uint256 shares) {
        Round storage r = _rounds[id];
        shares = stake[id][bettor];
        if (shares == 0) revert InvalidAmount();
        amount = Math.mulDiv(r.cash, shares, r.totalShares);
        delete stake[id][bettor];
        r.totalShares -= shares;
        totalSharesOutstanding -= shares;
        if (r.state == State.Open) unresolvedShares -= shares; // resolved rounds were released at reconciliation
        r.cash -= amount;
        accountedETH -= amount;
    }

    function claimFees(address payable recipient) external nonReentrant {
        _checkAddress(recipient);
        uint256 amount = feeCredit[msg.sender];
        if (amount == 0) revert InvalidAmount();
        delete feeCredit[msg.sender];
        accountedETH -= amount;
        emit FeesClaimed(msg.sender, recipient, amount);
        _send(recipient, amount);
    }

    function imdBalance() public view returns (uint256) {
        return imd.balanceOf(address(this));
    }

    function needsImdTopUp() external view returns (bool) {
        return imdBalance() < lowImdThreshold;
    }

    function withdrawIMD(address recipient, uint256 amount) external onlyOwner nonReentrant {
        _checkAddress(recipient);
        imd.safeTransfer(recipient, amount);
        emit ImdWithdrawn(recipient, amount);
    }

    function setRouter(address to) external onlyOwner nonReentrant {
        _checkAddress(to);
        _noBets();
        if (IKeelRouter(to).vault() != address(this) || IKeelRouter(to).pool() != address(fwa)) {
            revert InvalidParameter();
        }
        router = IKeelRouter(to);
        emit AddressSet("router", to);
    }

    function setFwa(address to) external onlyOwner nonReentrant {
        _checkAddress(to);
        _noBets();
        fwa = IFWAV2(to);
        emit AddressSet("fwa", to);
    }

    function setFloorOracle(address to) external onlyOwner {
        _checkAddress(to);
        _noActive();
        floorOracle = ICollectionFloorOracle(to);
        emit AddressSet("floorOracle", to);
    }

    function setIntake(address to) external onlyOwner {
        _checkAddress(to);
        _noActive();
        intake = IIntake(to);
        emit AddressSet("intake", to);
    }

    function setIMD(address to) external onlyOwner {
        _checkAddress(to);
        _noActive();
        imd = IERC20(to);
        emit AddressSet("imd", to);
    }

    function setOracleSigner(address to) external onlyOwner {
        _noActive();
        _setOracleSigner(to);
    }

    function setTeamWallet(address to) external onlyOwner {
        _checkAddress(to);
        if (to == address(this) || to == address(router)) revert InvalidAddress();
        teamWallet = to;
        if (_rounds[currentRoundId].totalShares == 0) _rounds[currentRoundId].feeRecipient = to;
        emit AddressSet("teamWallet", to);
    }

    function setBetsPaused(bool paused) external onlyOwner {
        betsPaused = paused;
        emit ParameterSet("betsPaused", paused ? 1 : 0);
    }

    function setBetParameters(uint256 minimum, uint16 maximumBettors, uint16 buffer) external onlyOwner {
        if (minimum == 0 || maximumBettors == 0 || maximumBettors > 500 || buffer > BPS) revert InvalidParameter();
        minBet = minimum;
        maxBettors = maximumBettors;
        bufferBps = buffer;
        emit BetParametersSet(minimum, maximumBettors, buffer);
    }

    function setSpinParameters(uint256 reward, uint256 gasPrice, uint256 weightedValue, uint16 negativeSlippage)
        external
        onlyOwner
    {
        if (gasPrice == 0 || negativeSlippage > BPS) revert InvalidParameter();
        spinReward = reward;
        maxSpinGasPrice = gasPrice;
        minWeightedValue = weightedValue;
        maxNegativeSlippageBps = negativeSlippage;
        emit SpinParametersSet(reward, gasPrice, weightedValue, negativeSlippage);
    }

    /// @dev Decision policy is read live by unresolved allocations, so it cannot change while one exists. The
    /// three timing settings must leave room inside the pool's live settlement window for a paid answer.
    function setDecisionParameters(
        uint16 haircut,
        uint16 margin,
        uint256 floorAge,
        uint256 safety,
        uint256 lead,
        uint256 oracleLead,
        bool keep
    ) external onlyOwner {
        _noActive();
        if (
            haircut > BPS || margin > BPS || floorAge == 0 || floorAge > 30 days || safety > 30 days || lead > 30 days
                || oracleLead > 30 days || safety + lead + oracleLead >= fwa.settlementWindow()
        ) revert InvalidParameter();
        haircutBps = haircut;
        marginBps = margin;
        maxFloorAge = floorAge;
        safetyMargin = safety;
        fallbackLead = lead;
        minOracleLead = oracleLead;
        defaultKeep = keep;
        emit DecisionParametersSet(haircut, margin, floorAge, safety, lead, oracleLead, keep);
    }

    function setFeeBps(uint16 fee) external onlyOwner {
        if (fee > 300) revert InvalidParameter();
        feeBps = fee;
        // An empty current round can take the new fee; funded rounds retain entry terms.
        if (_rounds[currentRoundId].totalShares == 0) {
            _rounds[currentRoundId].fee = fee;
            _rounds[currentRoundId].feeRecipient = teamWallet;
        }
        emit ParameterSet("feeBps", fee);
    }

    function setOraclePayment(bytes32 action, uint256 price, uint256 lowBalance) external onlyOwner {
        _noActive();
        if (action == 0 || price == 0 || lowBalance < price) revert InvalidParameter();
        oracleAction = action;
        oraclePrice = price;
        lowImdThreshold = lowBalance;
        emit OraclePaymentSet(action, price, lowBalance);
    }

    function setDefinition(uint256 index, string calldata value) external onlyOwner {
        if (index > 3) revert InvalidParameter();
        OracleBody.escape(value);
        definitions[index] = value;
        emit DefinitionSet(index, value);
    }

    function _noBets() internal view {
        if (unresolvedShares != 0 || activeRoundId != 0) revert OutstandingBets();
    }

    function _noActive() internal view {
        if (activeRoundId != 0) revert SpinInProgress();
    }

    function _checkAddress(address to) internal pure {
        if (to == address(0)) revert InvalidAddress();
    }

    function _state(uint256 id, State state) internal {
        _rounds[id].state = state;
        emit RoundStateChanged(id, state);
    }

    function _credit(Round storage r, uint256 amount) internal {
        r.cash += amount;
        accountedETH += amount;
    }

    function _send(address payable recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev Minimal on purpose: FWA may force ETH if a receiver exceeds its stipend. syncRound accounts it.
    receive() external payable {}
}
