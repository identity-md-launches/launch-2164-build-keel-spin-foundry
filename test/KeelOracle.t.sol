// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelBase} from "./KeelBase.t.sol";
import {KeelSpinVault} from "../src/KeelSpinVault.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {OracleBody} from "../src/OracleBody.sol";
import {MockFloor, RejectNFT} from "./mocks/Protocols.sol";

contract KeelOracleTest is KeelBase {
    function testColdOracleCallbackFits200kGas() public {
        (uint256 id, bytes32 requestId) = _ask();
        OracleAttestation.Attestation memory a = _attestation(2 ether);
        bytes memory signature = _sign(a);
        vm.cool(address(vault));
        vm.cool(address(pool));
        vm.cool(address(intake));
        assertTrue(intake.result(requestId, a, signature), "cold callback exceeded stipend");
        _state(id, KeelSpinVault.State.DecisionReady);
    }

    function testObviousKeep30EthFloorVersus1EthBacking() public {
        uint256 id = _ready();
        floor.set(30 ether, block.timestamp);
        vault.requestDecision(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertEq(intake.nonce(), 0);
        assertEq(nft.ownerOf(1), team);
        assertEq(uint256(vault.rounds(id).path), uint256(KeelSpinVault.DecisionPath.ObviousFloor));
    }

    function testStaleFloorSkipsPrecheckAndPaysExactIMD() public {
        uint256 id = _ready();
        floor.set(30 ether, block.timestamp - 24 hours - 1);
        vault.requestDecision(id);
        _state(id, KeelSpinVault.State.OraclePending);
        assertEq(intake.lastAmount(), 0.5 ether);
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        assertEq(imd.allowance(address(vault), address(intake)), 0);
        assertEq(intake.lastAction(), bytes32("oracle.request@oracle-1"));
        assertEq(intake.lastFailure(), vault.onFailure.selector);
    }

    function testFreshFloorBoundaryAndFutureTimestamp() public {
        uint256 id = _ready();
        floor.set(30 ether, block.timestamp - 24 hours);
        (bool available,) = vault.freshFloor(address(nft));
        assertTrue(available);
        floor.set(30 ether, block.timestamp + 1);
        (available,) = vault.freshFloor(address(nft));
        assertFalse(available);
        vault.requestDecision(id);
        _state(id, KeelSpinVault.State.OraclePending);
    }

    function testFloorFailureIsUnavailable() public {
        floor.setFails(true);
        (uint256 id,) = _ask();
        _state(id, KeelSpinVault.State.OraclePending);
    }

    function testBodyUsesAllocatedNFTAndExactDefinitions() public {
        (uint256 id,) = _ask();
        string memory body = string(intake.lastBody());
        assertEq(body, string(vault.oracleBody(id)));
        assertEq(vm.parseJsonUint(body, ".v"), 1);
        assertEq(vm.parseJsonUint(body, ".chainId"), 1);
        assertEq(vm.parseJsonString(body, ".answerType"), "uint256");
        assertEq(vm.parseJsonString(body, ".evidence"), "panel");
        assertEq(vm.parseJsonUint(body, ".window.hours"), 1);
        assertEq(vm.parseJsonUint(body, ".panelSize"), 5);
        assertEq(vm.parseJsonUint(body, ".quorum"), 4);
        assertEq(vm.parseJsonUint(body, ".toleranceBps"), 500);
        assertEq(vm.parseJsonUint(body, ".validForSeconds"), 3600);
        assertEq(vm.parseJsonString(body, ".guards.min"), "0");
        assertEq(vm.parseJsonString(body, ".guards.max"), "10000000000000000000000");
        assertEq(vm.parseJsonString(body, ".definitions.offers"), vault.definitions(0));
        assertTrue(bytes(vm.parseJsonString(body, ".question")).length > 100);
    }

    function testDefinitionsEscapedAndBounded() public {
        uint256 id = _ready();
        vault.setDefinition(0, 'Offer on "Blur" \\ fee');
        assertEq(vm.parseJsonString(string(vault.oracleBody(id)), ".definitions.offers"), 'Offer on "Blur" \\ fee');
        vm.expectRevert(OracleBody.InvalidDefinition.selector);
        vault.setDefinition(0, string(new bytes(512)));
        vm.expectRevert(OracleBody.InvalidDefinition.selector);
        vault.setDefinition(0, "bad\ntext");
        vm.expectRevert(OracleBody.InvalidDefinition.selector);
        vault.setDefinition(0, unicode"€");
        vm.expectRevert(KeelSpinVault.InvalidParameter.selector);
        vault.setDefinition(4, "no fifth definition");
    }

    function testOracleAboveMarginKeepsAndCallbackOnlyStores() public {
        (uint256 id,) = _ask();
        _answer(id, 0.945 ether + 1);
        _state(id, KeelSpinVault.State.DecisionReady);
        assertEq(nft.ownerOf(1), address(pool));
        vault.executeDecision(id);
        assertEq(nft.ownerOf(1), team);
        _state(id, KeelSpinVault.State.AwaitingSale);
    }

    function testOracleAtMarginTakesEth() public {
        (uint256 id,) = _ask();
        _answer(id, 0.945 ether);
        uint256 buffer = vault.rounds(id).cash;
        vault.executeDecision(id);
        _state(id, KeelSpinVault.State.Settled);
        assertEq(vault.claimable(id, alice), buffer + 0.9 ether);
        _solvent();
    }

    function testOracleBelowMarginAndZeroAreValidNoAnswers() public {
        (uint256 id,) = _ask();
        _answer(id, 0);
        vault.executeDecision(id);
        _state(id, KeelSpinVault.State.Settled);
        assertEq(nft.ownerOf(1), depositor);
    }

    function testDecisionReadsDiscountLive() public {
        (uint256 id,) = _ask();
        _answer(id, 0.945 ether);
        pool.setDiscount(8000);
        vault.executeDecision(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertEq(vault.rounds(id).ethBid, 0.8 ether);
    }

    function testOracleFailureFallbackImmediatelyAndNoSecondPaidRequest() public {
        (uint256 id, bytes32 requestId) = _ask();
        assertTrue(intake.fail(requestId));
        assertEq(vault.pending(requestId), 0);
        _state(id, KeelSpinVault.State.Allocated);
        floor.set(0.5 ether, block.timestamp);
        vault.requestDecision(id);
        assertEq(intake.nonce(), 1);
        _state(id, KeelSpinVault.State.Settled);
        assertFalse(intake.fail(requestId));
    }

    function testFallbackAtLeadClearsPendingAndRejectsLateAnswer() public {
        (uint256 id, bytes32 requestId) = _ask();
        vm.expectRevert(KeelSpinVault.TooEarly.selector);
        vault.settleFallback(id);
        vm.warp(vault.fallbackAt(id));
        vault.settleFallback(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertEq(vault.pending(requestId), 0);
        OracleAttestation.Attestation memory a = _attestation(0);
        assertFalse(intake.result(requestId, a, _sign(a)));
    }

    function testValidAnswerPreventsEarlyFallbackButDeadlineDoesNotLock() public {
        (uint256 id,) = _ask();
        uint256 fallbackTime = vault.fallbackAt(id);
        vm.warp(fallbackTime - 1);
        _answer(id, 2 ether);
        vm.warp(fallbackTime);
        vm.expectRevert(KeelSpinVault.TooEarly.selector);
        vault.settleFallback(id);
        vm.warp(vault.decisionDeadline(id));
        vm.expectRevert(KeelSpinVault.StaleAnswer.selector);
        vault.executeDecision(id);
        vault.settleFallback(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
    }

    function testAnswerAtMissingValueCutoffCannotRevokeFallback() public {
        (uint256 id, bytes32 requestId) = _ask();
        vm.warp(vault.fallbackAt(id));
        OracleAttestation.Attestation memory a = _attestation(2 ether);
        assertFalse(intake.result(requestId, a, _sign(a)));
        assertEq(vault.pending(requestId), id);
        vault.settleFallback(id);
        assertEq(vault.pending(requestId), 0);
        _state(id, KeelSpinVault.State.AwaitingSale);
    }

    function testExpiredStoredAnswerNeedsFallback() public {
        (uint256 id,) = _ask();
        _answer(id, 2 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(KeelSpinVault.StaleAnswer.selector);
        vault.executeDecision(id);
        vm.expectRevert(KeelSpinVault.TooEarly.selector);
        vault.settleFallback(id);
        _fallback(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
    }

    function testShortLiveWindowSaturatesAndDoesNotPayOracle() public {
        // A window shorter than the configured timing (pool governance change after configuration) saturates.
        pool.setWindow(20 minutes);
        uint256 id = _ready();
        assertEq(vault.decisionDeadline(id), block.timestamp + 10 minutes);
        assertEq(vault.fallbackAt(id), block.timestamp);
        vault.requestDecision(id);
        assertEq(intake.nonce(), 0);
        _state(id, KeelSpinVault.State.AwaitingSale);
    }

    function testLiveOneHourWindowLeavesRoomForPaidOracleDecision() public {
        pool.setWindow(1 hours);
        uint256 id = _ready();
        uint256 allocatedAt = vault.rounds(id).allocatedAt;
        assertEq(vault.decisionDeadline(id), allocatedAt + 50 minutes);
        assertEq(vault.fallbackAt(id), allocatedAt + 30 minutes);
        vault.requestDecision(id);
        _state(id, KeelSpinVault.State.OraclePending);
        assertEq(intake.nonce(), 1);
        vm.warp(block.timestamp + 5 minutes);
        _answer(id, 2 ether);
        vault.executeDecision(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertEq(nft.ownerOf(1), team);
        assertEq(uint256(vault.rounds(id).path), uint256(KeelSpinVault.DecisionPath.Oracle));
    }

    function testNoPaidAskWhenAnswerCouldNotLandBeforeFallback() public {
        uint256 id = _ready();
        floor.set(0.5 ether, block.timestamp);
        uint256 imdBefore = vault.imdBalance();
        // Exactly minOracleLead seconds left: an answer would have to land before fallbackAt, so less room than
        // the configured lead. No paid ask.
        vm.warp(vault.fallbackAt(id) - vault.minOracleLead());
        vault.requestDecision(id);
        assertEq(intake.nonce(), 0);
        assertEq(vault.imdBalance(), imdBefore);
        _state(id, KeelSpinVault.State.Settled);
        assertEq(uint256(vault.rounds(id).path), uint256(KeelSpinVault.DecisionPath.FallbackFloor));
    }

    function testLastMomentPaidAskStillAccepted() public {
        uint256 id = _ready();
        vm.warp(vault.fallbackAt(id) - vault.minOracleLead() - 1);
        vault.requestDecision(id);
        _state(id, KeelSpinVault.State.OraclePending);
        assertEq(intake.nonce(), 1);
        // The answer still lands strictly before fallbackAt, which is the last instant onOracleResult accepts.
        vm.warp(vault.fallbackAt(id) - 1);
        _answer(id, 2 ether);
        _state(id, KeelSpinVault.State.DecisionReady);
    }

    function testZeroLeadNeverPaysForAnUnanswerableQuestion() public {
        vault.setDecisionParameters(1500, 500, 24 hours, 10 minutes, 20 minutes, 0, true);
        uint256 id = _ready();
        uint256 imdBefore = vault.imdBalance();
        vm.warp(vault.fallbackAt(id));
        vault.requestDecision(id);
        assertEq(intake.nonce(), 0, "paid ask sent at fallbackAt");
        assertEq(vault.imdBalance(), imdBefore, "IMD spent on an unanswerable request");
        // No floor is set, so the fallback rule applied defaultKeep.
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertEq(uint256(vault.rounds(id).path), uint256(KeelSpinVault.DecisionPath.FallbackDefault));
        assertEq(nft.ownerOf(1), team);
    }

    function testZeroLeadStillAsksOneSecondBeforeFallback() public {
        vault.setDecisionParameters(1500, 500, 24 hours, 10 minutes, 20 minutes, 0, true);
        uint256 id = _ready();
        vm.warp(vault.fallbackAt(id) - 1);
        vault.requestDecision(id);
        _state(id, KeelSpinVault.State.OraclePending);
        assertEq(intake.nonce(), 1);
        _answer(id, 2 ether);
        _state(id, KeelSpinVault.State.DecisionReady);
    }

    function testTimingParametersMustFitLiveWindow() public {
        pool.setWindow(1 hours);
        vm.expectRevert(KeelSpinVault.InvalidParameter.selector);
        vault.setDecisionParameters(1500, 500, 24 hours, 20 minutes, 20 minutes, 20 minutes, true);
        vault.setDecisionParameters(1500, 500, 24 hours, 20 minutes, 20 minutes, 19 minutes, true);
        assertEq(vault.minOracleLead(), 19 minutes);
    }

    function testResolvedRoundReentryRetriesForwardInsteadOfReverting() public {
        RejectNFT recipient = new RejectNFT();
        vault.setTeamWallet(address(recipient));
        uint256 id = _ready();
        floor.set(30 ether, block.timestamp);
        vault.requestDecision(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertEq(vault.activeRoundId(), 0);
        vault.requestDecision(id);
        vault.executeDecision(id);
        vault.settleFallback(id);
        vault.syncRound(id);
        assertEq(nft.ownerOf(1), address(vault));
        recipient.setReject(false);
        vault.executeDecision(id);
        assertEq(nft.ownerOf(1), address(recipient));
        vault.settleFallback(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
    }

    function testFallbackFreshFloorUsesMarginAndStrictComparison() public {
        (uint256 id, bytes32 requestId) = _ask();
        assertTrue(intake.fail(requestId));
        floor.set(1 ether, block.timestamp);
        vault.settleFallback(id);
        _state(id, KeelSpinVault.State.Settled);
    }

    function testFallbackFreshHighFloorKeeps() public {
        (uint256 id, bytes32 requestId) = _ask();
        assertTrue(intake.fail(requestId));
        floor.set(2 ether, block.timestamp);
        vault.settleFallback(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
    }

    function testFallbackNoFloorUsesOwnerSetDefault() public {
        vault.setDecisionParameters(1500, 500, 24 hours, 2 hours, 1 hours, 10 minutes, false);
        uint256 id = _ready();
        _fallback(id);
        _state(id, KeelSpinVault.State.Settled);
    }

    function testLowImdDoesNotSpendBettorEthAndCanBeRetriedAfterTopUp() public {
        uint256 balance = vault.imdBalance();
        vault.withdrawIMD(team, balance);
        assertTrue(vault.needsImdTopUp());
        uint256 id = _ready();
        uint256 cash = vault.rounds(id).cash;
        vault.requestDecision(id);
        _state(id, KeelSpinVault.State.Allocated);
        assertEq(intake.nonce(), 0);
        assertEq(vault.rounds(id).cash, cash);
        imd.mint(address(vault), 2 ether);
        assertFalse(vault.needsImdTopUp());
        vault.requestDecision(id);
        assertTrue(vault.needsImdTopUp());
        _state(id, KeelSpinVault.State.OraclePending);
    }

    function testIntakePriceChangeDoesNotOverpay() public {
        uint256 id = _ready();
        intake.setPrice(1 ether);
        vm.expectRevert(KeelSpinVault.InvalidParameter.selector);
        vault.requestDecision(id);
        assertEq(intake.nonce(), 0);
        assertEq(imd.balanceOf(address(intake)), 0);
    }

    function testNonIntakeAndUnknownCallbacksRejected() public {
        (uint256 id, bytes32 requestId) = _ask();
        OracleAttestation.Attestation memory a = _attestation(1 ether);
        bytes memory signature = _sign(a);
        vm.expectRevert(KeelSpinVault.NotIntake.selector);
        vault.onOracleResult(requestId, a, signature);
        vm.expectRevert(KeelSpinVault.NotIntake.selector);
        vault.onFailure(requestId, 2, bytes32(0), 0, 0, "");
        vm.prank(address(intake));
        vm.expectRevert(KeelSpinVault.UnknownRequest.selector);
        vault.onOracleResult(bytes32(uint256(999)), a, signature);
        assertEq(vault.pending(requestId), id);
    }

    function testBadSignatureTamperingAndReplayRejected() public {
        (uint256 id, bytes32 requestId) = _ask();
        OracleAttestation.Attestation memory a = _attestation(1 ether);
        bytes memory signature = _sign(a);
        a.answer = abi.encode(4 ether);
        assertFalse(intake.result(requestId, a, signature));
        a.answer = abi.encode(1 ether);
        assertFalse(intake.result(requestId, a, hex"1234"));
        assertTrue(intake.result(requestId, a, signature));
        assertFalse(intake.result(requestId, a, signature));
        assertTrue(vault.consumed(a.requestId));
        assertEq(vault.pending(requestId), 0);
        _state(id, KeelSpinVault.State.DecisionReady);
    }

    function testInvalidPanelChainTypeExpiryAndBoundsRejected() public {
        (, bytes32 requestId) = _ask();
        OracleAttestation.Attestation memory a = _attestation(1 ether);
        a.agreed = 3;
        assertFalse(intake.result(requestId, a, _sign(a)));
        a.agreed = 4;
        a.quorum = 3;
        assertFalse(intake.result(requestId, a, _sign(a)));
        a.quorum = 4;
        a.panelSize = 4;
        assertFalse(intake.result(requestId, a, _sign(a)));
        a.panelSize = 5;
        a.chainId = 2;
        assertFalse(intake.result(requestId, a, _sign(a)));
        a.chainId = 1;
        a.answerType = 0;
        assertFalse(intake.result(requestId, a, _sign(a)));
        a.answerType = 3;
        a.answer = abi.encode(uint256(1e22 + 1));
        assertFalse(intake.result(requestId, a, _sign(a)));
        a.answer = abi.encode(uint256(1 ether));
        a.expiresAt = uint64(block.timestamp - 1);
        assertFalse(intake.result(requestId, a, _sign(a)));
        a.issuedAt = uint64(block.timestamp + 301);
        a.expiresAt = a.issuedAt + 3600;
        assertFalse(intake.result(requestId, a, _sign(a)));
    }

    function testAttestationCannotCrossConsumerDomain() public {
        (, bytes32 requestId) = _ask();
        OracleAttestation.Attestation memory a = _attestation(1 ether);
        KeelSpinVault other = new KeelSpinVault(
            address(this), address(pool), address(floor), address(intake), address(imd), vm.addr(SIGNER_KEY), team
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, other.attestationDigest(a));
        assertFalse(intake.result(requestId, a, abi.encodePacked(r, s, v)));
    }

    function testOracleCannotRotateDuringPendingRound() public {
        _ask();
        vm.expectRevert(KeelSpinVault.SpinInProgress.selector);
        vault.setIntake(address(intake));
        vm.expectRevert(KeelSpinVault.SpinInProgress.selector);
        vault.setOracleSigner(team);
        vm.expectRevert(KeelSpinVault.SpinInProgress.selector);
        vault.setIMD(address(imd));
    }

    function testOwnerCannotFlipAllocatedRoundThroughFloorOrPolicy() public {
        uint256 id = _ready();
        floor.set(0.5 ether, block.timestamp);
        MockFloor fake = new MockFloor();
        fake.set(100 ether, block.timestamp);
        vm.expectRevert(KeelSpinVault.SpinInProgress.selector);
        vault.setFloorOracle(address(fake));
        vm.expectRevert(KeelSpinVault.SpinInProgress.selector);
        vault.setDecisionParameters(0, 500, 24 hours, 10 minutes, 20 minutes, 10 minutes, true);
        uint256 buffer = vault.rounds(id).cash;
        _fallback(id);
        _state(id, KeelSpinVault.State.Settled);
        assertEq(nft.ownerOf(1), depositor);
        assertEq(vault.claimable(id, alice), buffer + 0.9 ether);
        vault.setFloorOracle(address(fake));
        vault.setDecisionParameters(0, 500, 24 hours, 10 minutes, 20 minutes, 10 minutes, true);
        assertEq(address(vault.floorOracle()), address(fake));
    }
}
