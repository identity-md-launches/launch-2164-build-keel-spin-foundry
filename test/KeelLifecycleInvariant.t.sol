// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeelBase} from "./KeelBase.t.sol";
import {KeelSpinVault} from "src/KeelSpinVault.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {MockFWA, MockNFT, MockFloor, MockIntake} from "./mocks/Protocols.sol";

/// @dev The flow ledger uses user inputs and counterparty ETH balances, never accountedETH
/// or changes in the vault balance. Unexpected reverts fail this campaign.
contract LifecycleHandler is Test {
    KeelSpinVault public vault;
    MockFWA public pool;
    MockNFT public nft;
    MockFloor public floor;
    MockIntake public intake;
    address public team;
    address public owner;
    address[8] public actors;
    uint256 private signerKey;
    uint256 private tokenId;

    uint256 public deposits;
    uint256 public donations;
    uint256 public sales;
    uint256 public poolPayments;
    uint256 public poolReceipts;
    uint256 public keeperRewards;
    uint256 public withdrawals;
    uint256 public claims;
    uint256 public fees;
    uint256 public paidRequests;
    uint256 public validResults;
    uint256 public failedResults;
    uint256 public rejectedResults;
    uint256 public refunds;
    uint256 public externalResolutions;
    uint256 public oracleDecisions;
    uint256 public fallbackDecisions;
    uint256 public saleCount;
    mapping(uint256 => bool) public wasSettled;

    constructor(KeelSpinVault vault_, MockFWA pool_, MockNFT nft_, MockFloor floor_, MockIntake intake_, uint256 key_) {
        vault = vault_;
        pool = pool_;
        nft = nft_;
        floor = floor_;
        intake = intake_;
        team = vault.teamWallet();
        owner = vault.owner();
        signerKey = key_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(0x710000 + i));
        }
    }

    function deposit(uint256 actorSeed, uint256 amountSeed, uint256 roundSeed) external {
        if (vault.betsPaused()) return;
        uint256 id = _findOpen(roundSeed);
        uint256 amount = bound(amountSeed, vault.minBet(), vault.liveTarget() * 2);
        _deposit(id, actors[actorSeed % actors.length], amount);
    }

    function _deposit(uint256 id, address actor, uint256 amount) private {
        vm.deal(actor, actor.balance + amount);
        vm.prank(actor);
        vault.betInto{value: amount}(id);
        deposits += amount;
    }

    function _findOpen(uint256 seed) private view returns (uint256) {
        uint256 count = vault.roundCount();
        for (uint256 i; i < count; ++i) {
            uint256 id = 1 + (seed % count + i) % count;
            if (vault.rounds(id).state == KeelSpinVault.State.Open) return id;
        }
        revert("fixture must always have an open round");
    }

    function fundAndSpin(uint256 seed) external {
        if (vault.activeRoundId() != 0 || vault.betsPaused()) return;
        if (block.timestamp % 12 hours >= 11 hours + 45 minutes) return;
        uint256 id = _findOpen(seed);
        (,, uint256 quote) = pool.quoteAcquisitionPrice();
        uint256 reward = vault.effectiveSpinReward(quote);
        uint256 cash = vault.rounds(id).cash;
        if (cash < quote + reward) {
            uint256 topUp = vault.liveTarget() - cash;
            _deposit(id, actors[seed % actors.length], topUp < vault.minBet() ? vault.minBet() : topUp);
        }
        uint256 beforePool = address(pool).balance;
        uint256 beforeKeeper = address(this).balance;
        vault.spin(id);
        poolPayments += address(pool).balance - beforePool;
        keeperRewards += address(this).balance - beforeKeeper;
        assertEq(address(this).balance - beforeKeeper, reward, "reward differs from live quote cap");
    }

    function fulfill(uint256 mode, uint256 backingSeed) external {
        uint256 id = vault.activeRoundId();
        if (id == 0) return;
        KeelSpinVault.Round memory r = vault.rounds(id);
        if (r.state != KeelSpinVault.State.Spinning) return;
        uint256 beforePool = address(pool).balance;
        if (mode % 3 == 0) {
            pool.refund(r.requestId, mode % 2 == 0);
            ++refunds;
        } else {
            pool.allocate(r.requestId, nft, ++tokenId, bound(backingSeed, 1, 5 ether), owner);
        }
        vault.syncRound(id);
        poolReceipts += beforePool - address(pool).balance;
    }

    function request(uint256 floorMode) external {
        uint256 id = vault.activeRoundId();
        if (id == 0) return;
        KeelSpinVault.Round memory r = vault.rounds(id);
        if (r.state != KeelSpinVault.State.Allocated) return;
        uint256 mode = floorMode % 4;
        floor.set(
            mode == 0 ? 0 : mode == 1 ? r.backing * 10 : r.backing / 2,
            mode == 3 ? block.timestamp - 25 hours : block.timestamp
        );
        uint256 beforePool = address(pool).balance;
        uint256 requestsBefore = intake.nonce();
        vault.requestDecision(id);
        paidRequests += intake.nonce() - requestsBefore;
        _recordResolution(id, beforePool);
    }

    function result(uint256 offerSeed, bool failure) external {
        uint256 id = vault.activeRoundId();
        if (id == 0) return;
        KeelSpinVault.Round memory r = vault.rounds(id);
        if (r.state != KeelSpinVault.State.OraclePending) return;
        if (failure) {
            uint256 cashBefore = address(vault).balance;
            assertTrue(intake.fail(r.oracleRequestId), "known failure callback must fit stipend");
            assertEq(address(vault).balance, cashBefore, "failure callback moved ETH");
            assertEq(nft.ownerOf(r.tokenId), address(pool), "failure callback moved NFT");
            ++failedResults;
        } else if (block.timestamp < vault.fallbackAt(id)) {
            OracleAttestation.Attestation memory a = _attestation(bound(offerSeed, 0, 10 ether));
            uint256 cashBefore = address(vault).balance;
            bytes memory signature = _sign(a);
            vm.cool(address(vault));
            vm.cool(address(pool));
            assertTrue(intake.result(r.oracleRequestId, a, signature), "valid callback must fit cold 200k stipend");
            assertEq(address(vault).balance, cashBefore, "value callback moved ETH");
            assertEq(nft.ownerOf(r.tokenId), address(pool), "value callback moved NFT");
            assertEq(vault.pending(r.oracleRequestId), 0);
            ++validResults;
        }
    }

    function badResult(uint256 offerSeed) external {
        uint256 id = vault.activeRoundId();
        if (id == 0 || vault.rounds(id).state != KeelSpinVault.State.OraclePending) return;
        KeelSpinVault.Round memory r = vault.rounds(id);
        OracleAttestation.Attestation memory a = _attestation(bound(offerSeed, 0, 10 ether));
        bytes memory signature = _sign(a);
        a.answer = abi.encode(abi.decode(a.answer, (uint256)) + 1);
        assertFalse(intake.result(r.oracleRequestId, a, signature), "tampered value accepted");
        assertEq(keccak256(abi.encode(vault.rounds(id))), keccak256(abi.encode(r)), "bad callback changed round");
        assertEq(vault.pending(r.oracleRequestId), id);
        assertFalse(vault.consumed(a.requestId));
        ++rejectedResults;
    }

    function _attestation(uint256 offer) private view returns (OracleAttestation.Attestation memory a) {
        a.requestId = keccak256(abi.encode("lifecycle oracle UUID", intake.nonce()));
        a.chainId = 1;
        a.questionHash = keccak256("resolved relative window and definitions");
        a.answerType = 3;
        a.answer = abi.encode(offer);
        a.figure = offer;
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
    }

    function _sign(OracleAttestation.Attestation memory a) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, vault.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function decide() external {
        uint256 id = vault.activeRoundId();
        if (id == 0) return;
        KeelSpinVault.Round memory r = vault.rounds(id);
        if (r.state == KeelSpinVault.State.Spinning) return;
        bool valid = r.state == KeelSpinVault.State.DecisionReady && block.timestamp <= r.answerExpiresAt;
        uint256 beforePool = address(pool).balance;
        if (valid && block.timestamp < vault.decisionDeadline(id)) {
            vault.executeDecision(id);
            ++oracleDecisions;
        } else if (
            r.oracleFailed || block.timestamp >= vault.decisionDeadline(id)
                || (block.timestamp >= vault.fallbackAt(id) && !valid)
        ) {
            vault.settleFallback(id);
            ++fallbackDecisions;
        } else {
            return;
        }
        _recordResolution(id, beforePool);
    }

    function externalResolve(bool takeETH) external {
        uint256 id = vault.activeRoundId();
        if (id == 0) return;
        KeelSpinVault.Round memory r = vault.rounds(id);
        if (r.listingId == 0 || block.timestamp < r.allocatedAt + pool.settlementWindow()) return;
        uint256 beforePool = address(pool).balance;
        if (takeETH) {
            vm.prank(owner);
            pool.depositorReclaimNFT(r.listingId);
        } else {
            pool.finalizeUnsettled(r.listingId);
        }
        vault.syncRound(id);
        _recordResolution(id, beforePool);
        ++externalResolutions;
    }

    function _recordResolution(uint256 id, uint256 beforePool) private {
        poolReceipts += beforePool - address(pool).balance;
        if (vault.rounds(id).state == KeelSpinVault.State.Settled) wasSettled[id] = true;
    }

    function sell(uint256 seed, uint256 amountSeed) external {
        uint256 count = vault.roundCount();
        for (uint256 i; i < count; ++i) {
            uint256 id = 1 + (seed % count + i) % count;
            if (vault.rounds(id).state != KeelSpinVault.State.AwaitingSale) continue;
            _sell(id, bound(amountSeed, 1, 8 ether));
            return;
        }
    }

    function _sell(uint256 id, uint256 amount) private {
        vm.deal(team, team.balance + amount);
        vm.prank(team);
        vault.depositSaleProceeds{value: amount}(id, keccak256(abi.encode("sale", id)));
        sales += amount;
        ++saleCount;
        wasSettled[id] = true;
    }

    function cashOut(uint256 roundSeed, uint256 actorSeed) external {
        uint256 count = vault.roundCount();
        for (uint256 i; i < count; ++i) {
            uint256 id = 1 + (roundSeed % count + i) % count;
            KeelSpinVault.State state = vault.rounds(id).state;
            if (state != KeelSpinVault.State.Open && state != KeelSpinVault.State.Settled) continue;
            for (uint256 j; j < actors.length; ++j) {
                address actor = actors[(actorSeed % actors.length + j) % actors.length];
                if (vault.stake(id, actor) == 0) continue;
                _cashOut(id, actor, state);
                return;
            }
        }
    }

    function _cashOut(uint256 id, address actor, KeelSpinVault.State state) private {
        uint256 beforeBalance = actor.balance;
        uint256 expected =
            state == KeelSpinVault.State.Open ? vault.withdrawable(id, actor) : vault.claimable(id, actor);
        vm.prank(actor);
        if (state == KeelSpinVault.State.Open) vault.withdraw(id);
        else vault.claim(id);
        uint256 received = actor.balance - beforeBalance;
        assertEq(received, expected, "preview differs from actual payment");
        assertEq(vault.stake(id, actor), 0, "payout did not burn shares");
        if (state == KeelSpinVault.State.Open) withdrawals += received;
        else claims += received;
    }

    function claimFees() public {
        if (vault.feeCredit(team) == 0) return;
        uint256 beforeBalance = team.balance;
        vm.prank(team);
        vault.claimFees(payable(team));
        fees += team.balance - beforeBalance;
    }

    function changeMarket(uint256 feeSeed, uint256 vrfSeed, uint256 rebateSeed, uint256 discountSeed) external {
        uint256 fee = bound(feeSeed, 0.03 ether, 0.3 ether);
        pool.setPrice(fee, bound(vrfSeed, 0, 0.01 ether));
        pool.setRebate(bound(rebateSeed, 0, fee / 10));
        pool.setDiscount(bound(discountSeed, 0, 10000));
    }

    function setPolicy(bool paused, uint256 feeSeed) external {
        vm.prank(owner);
        vault.setBetsPaused(paused);
        vm.prank(owner);
        vault.setFeeBps(uint16(bound(feeSeed, 0, 300)));
    }

    function elapse(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 25 hours));
        vm.roll(block.number + 1);
    }

    function donate(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 0.1 ether);
        vm.deal(address(this), address(this).balance + amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
        donations += amount;
    }

    /// @dev Run only after a sequence: every owned share must still have a route to payment.
    function closeAll() external {
        uint256 active = vault.activeRoundId();
        if (active != 0) {
            KeelSpinVault.Round memory r = vault.rounds(active);
            uint256 beforePool = address(pool).balance;
            if (r.state == KeelSpinVault.State.Spinning) {
                pool.refund(r.requestId, false);
            } else {
                vm.warp(block.timestamp + pool.settlementWindow());
                pool.finalizeUnsettled(r.listingId);
            }
            vault.syncRound(active);
            _recordResolution(active, beforePool);
        }
        for (uint256 id = 1; id <= vault.roundCount(); ++id) {
            if (vault.rounds(id).state == KeelSpinVault.State.AwaitingSale) _sell(id, 1 ether);
            KeelSpinVault.State state = vault.rounds(id).state;
            for (uint256 j; j < actors.length; ++j) {
                if (vault.stake(id, actors[j]) != 0) _cashOut(id, actors[j], state);
            }
        }
        claimFees();
    }

    receive() external payable {}
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract KeelLifecycleInvariantTest is KeelBase {
    LifecycleHandler internal lifecycle;

    function setUp() public override {
        super.setUp();
        vault.setFeeBps(137);
        lifecycle = new LifecycleHandler(vault, pool, nft, floor, intake, SIGNER_KEY);
        targetContract(address(lifecycle));
        // Forge funds outer transaction senders for gas. Never let it choose the vault,
        // router or pool and inject ETH outside the ghost ledger. Actors vary inside the handler.
        targetSender(makeAddr("lifecycle-driver"));
        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = lifecycle.deposit.selector;
        selectors[1] = lifecycle.fundAndSpin.selector;
        selectors[2] = lifecycle.fulfill.selector;
        selectors[3] = lifecycle.request.selector;
        selectors[4] = lifecycle.result.selector;
        selectors[5] = lifecycle.badResult.selector;
        selectors[6] = lifecycle.decide.selector;
        selectors[7] = lifecycle.externalResolve.selector;
        selectors[8] = lifecycle.sell.selector;
        selectors[9] = lifecycle.cashOut.selector;
        selectors[10] = lifecycle.claimFees.selector;
        selectors[11] = lifecycle.changeMarket.selector;
        selectors[12] = lifecycle.setPolicy.selector;
        selectors[13] = lifecycle.elapse.selector;
        selectors[14] = lifecycle.donate.selector;
        // More weight on starting spins; preconditions prevent invalid-state churn.
        selectors[15] = lifecycle.fundAndSpin.selector;
        targetSelector(FuzzSelector(address(lifecycle), selectors));
    }

    function invariantIndependentEthFlowLedger() public view {
        uint256 incoming = lifecycle.deposits() + lifecycle.donations() + lifecycle.sales() + lifecycle.poolReceipts();
        uint256 outgoing = lifecycle.poolPayments() + lifecycle.keeperRewards() + lifecycle.withdrawals()
            + lifecycle.claims() + lifecycle.fees();
        assertEq(address(vault).balance + outgoing, incoming, "ETH created, lost or paid to an untracked recipient");
        assertEq(address(router).balance, 0, "router retained bettor overpayment");
    }

    function invariantLiabilitiesSharesAndTerminalStates() public view {
        uint256 allCash;
        uint256 allShares;
        uint256 liability;
        uint256 active;
        for (uint256 id = 1; id <= vault.roundCount(); ++id) {
            KeelSpinVault.Round memory r = vault.rounds(id);
            uint256 shares;
            uint256 bettors;
            for (uint256 j; j < 8; ++j) {
                address actor = lifecycle.actors(j);
                uint256 s = vault.stake(id, actor);
                shares += s;
                if (s != 0) ++bettors;
                liability += vault.claimable(id, actor);
            }
            assertEq(shares, r.totalShares, "shares without an owner");
            if (r.state == KeelSpinVault.State.Open) {
                assertEq(bettors, r.bettors, "withdrawal did not release bettor capacity");
                liability += r.cash;
            }
            if (lifecycle.wasSettled(id)) assertEq(uint256(r.state), uint256(KeelSpinVault.State.Settled));
            if (r.state >= KeelSpinVault.State.Spinning && r.state <= KeelSpinVault.State.DecisionReady) {
                ++active;
                assertEq(vault.activeRoundId(), id);
            }
            if (r.oracleRequestId != 0) {
                assertEq(vault.pending(r.oracleRequestId), r.state == KeelSpinVault.State.OraclePending ? id : 0);
            }
            if (r.state == KeelSpinVault.State.AwaitingSale) {
                assertTrue(r.nftForwarded);
                assertEq(nft.ownerOf(r.tokenId), team);
            }
            allCash += r.cash;
            allShares += shares;
        }
        assertLe(active, 1);
        assertEq(active == 0, vault.activeRoundId() == 0);
        assertEq(allShares, vault.totalSharesOutstanding());
        assertEq(allCash + vault.feeCredit(team), vault.accountedETH());
        assertLe(liability + vault.feeCredit(team), address(vault).balance);
        assertLe(vault.accountedETH(), address(vault).balance);
    }

    function invariantImdOnlyPaysOwnRequests() public view {
        assertEq(imd.balanceOf(address(intake)), lifecycle.paidRequests() * 0.5 ether);
        assertEq(imd.balanceOf(address(vault)) + imd.balanceOf(address(intake)), 100 ether);
        assertEq(imd.allowance(address(vault), address(intake)), 0);
    }

    function afterInvariant() public {
        lifecycle.closeAll();
        invariantIndependentEthFlowLedger();
        assertEq(vault.totalSharesOutstanding(), 0, "some bettor cannot exit");
        assertEq(vault.accountedETH(), 0, "some cash or fee cannot be claimed");
        assertLe(address(vault).balance, lifecycle.donations(), "non-donation ETH stranded after all exits");
    }

    /// @dev Explicitly demonstrates that the handler can reach every important branch.
    function testLifecycleHandlerExercisesOracleRefundFallbackAndExternalResolution() public {
        lifecycle.fundAndSpin(0);
        lifecycle.fulfill(0, 1 ether);
        assertEq(lifecycle.refunds(), 1);
        lifecycle.cashOut(0, 0);
        lifecycle.fundAndSpin(1);
        lifecycle.fulfill(1, 1 ether);
        lifecycle.request(0);
        lifecycle.badResult(1 ether);
        lifecycle.result(2 ether, false);
        lifecycle.decide();
        lifecycle.sell(0, 3 ether);
        lifecycle.fundAndSpin(2);
        lifecycle.fulfill(1, 1 ether);
        lifecycle.request(0);
        lifecycle.result(0, true);
        lifecycle.decide();
        lifecycle.sell(0, 1 ether);
        lifecycle.fundAndSpin(3);
        lifecycle.fulfill(1, 1 ether);
        lifecycle.request(0);
        lifecycle.result(0, false);
        lifecycle.decide();
        lifecycle.fundAndSpin(4);
        lifecycle.fulfill(1, 1 ether);
        lifecycle.elapse(24 hours);
        lifecycle.externalResolve(true);
        lifecycle.donate(123);
        assertEq(lifecycle.paidRequests(), 3);
        assertEq(lifecycle.validResults(), 2);
        assertEq(lifecycle.failedResults(), 1);
        assertEq(lifecycle.rejectedResults(), 1);
        assertEq(lifecycle.oracleDecisions(), 2);
        assertEq(lifecycle.fallbackDecisions(), 1);
        assertEq(lifecycle.externalResolutions(), 1);
        assertEq(lifecycle.saleCount(), 2);
        invariantIndependentEthFlowLedger();
        invariantLiabilitiesSharesAndTerminalStates();
        invariantImdOnlyPaysOwnRequests();
        afterInvariant();
    }
}
