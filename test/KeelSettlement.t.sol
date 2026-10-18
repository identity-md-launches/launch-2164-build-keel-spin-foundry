// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelBase} from "./KeelBase.t.sol";
import {KeelSpinVault} from "../src/KeelSpinVault.sol";
import {RejectNFT} from "./mocks/Protocols.sol";

contract KeelSettlementTest is KeelBase {
    function testDepositorResolvesETHBeforeSyncAllocation() public {
        uint256 id = _fund();
        _spin(id);
        uint256 listing = pool.allocate(vault.rounds(id).requestId, nft, ++tokenCounter, 1 ether, depositor);
        uint256 buffer = vault.rounds(id).cash;
        vm.warp(block.timestamp + pool.settlementWindow());
        vm.prank(depositor);
        pool.depositorReclaimNFT(listing);
        vault.syncRound(id);
        _state(id, KeelSpinVault.State.Settled);
        assertEq(vault.claimable(id, alice), buffer + 0.9 ether);
        assertEq(uint256(vault.rounds(id).path), uint256(KeelSpinVault.DecisionPath.External));
        _solvent();
    }

    function testDepositorResolvesDuringOracleRequest() public {
        (uint256 id, bytes32 requestId) = _ask();
        vm.warp(block.timestamp + pool.settlementWindow());
        uint256 listing = vault.rounds(id).listingId;
        vm.prank(depositor);
        pool.depositorReclaimNFT(listing);
        vault.executeDecision(id);
        _state(id, KeelSpinVault.State.Settled);
        assertEq(vault.pending(requestId), 0);
        assertEq(vault.activeRoundId(), 0);
    }

    function testDepositorReclaimBackingDeliversWithoutReceiverHook() public {
        uint256 id = _ready();
        vm.warp(block.timestamp + pool.settlementWindow());
        uint256 listing = vault.rounds(id).listingId;
        vm.prank(depositor);
        pool.depositorReclaimBacking(listing);
        assertEq(nft.ownerOf(1), address(vault));
        vault.syncRound(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertEq(nft.ownerOf(1), team);
    }

    function testFinalizerResolvesFirst() public {
        uint256 id = _ready();
        vm.warp(block.timestamp + pool.settlementWindow());
        pool.finalizeUnsettled(vault.rounds(id).listingId);
        vault.settleFallback(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertEq(nft.ownerOf(1), team);
    }

    function testRecoverProtocolStuckNFTAndForward() public {
        uint256 id = _ready();
        nft.setRejectTransfers(true);
        vm.warp(block.timestamp + pool.settlementWindow());
        pool.finalizeUnsettled(vault.rounds(id).listingId);
        vault.syncRound(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertEq(pool.stuckNFTRecipient(vault.rounds(id).listingId), address(vault));
        vm.expectRevert("NFT transfer disabled");
        vault.recoverStuckNFT(id);
        nft.setRejectTransfers(false);
        vault.recoverStuckNFT(id);
        assertEq(nft.ownerOf(1), team);
        assertTrue(vault.rounds(id).nftForwarded);
    }

    function testTeamRejectingNFTDoesNotUndoKeepAndCanRetry() public {
        RejectNFT recipient = new RejectNFT();
        vault.setTeamWallet(address(recipient));
        uint256 id = _ready();
        floor.set(30 ether, block.timestamp);
        vault.requestDecision(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertEq(nft.ownerOf(1), address(vault));
        assertFalse(vault.rounds(id).nftForwarded);
        recipient.setReject(false);
        vault.forwardNFT(id);
        assertEq(nft.ownerOf(1), address(recipient));
        assertTrue(vault.rounds(id).nftForwarded);
        vault.forwardNFT(id);
        assertEq(nft.ownerOf(1), address(recipient));
    }

    function testTeamCanBeUpdatedToRecoverForwarding() public {
        RejectNFT recipient = new RejectNFT();
        vault.setTeamWallet(address(recipient));
        uint256 id = _ready();
        floor.set(30 ether, block.timestamp);
        vault.requestDecision(id);
        vault.setTeamWallet(team);
        vault.forwardNFT(id);
        assertEq(nft.ownerOf(1), team);
    }

    function testSettlementFailureKeepsDecisionRetryable() public {
        (uint256 id,) = _ask();
        _answer(id, 2 ether);
        pool.setFailures(false, true);
        vm.expectRevert("not purchaser");
        vault.executeDecision(id);
        _state(id, KeelSpinVault.State.DecisionReady);
        assertEq(vault.activeRoundId(), id);
        pool.setFailures(false, false);
        vault.executeDecision(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
    }

    function testUndeliverableKeepCanEventuallyUseEthFallback() public {
        (uint256 id,) = _ask();
        _answer(id, 2 ether);
        nft.setRejectTransfers(true);
        vm.expectRevert("NFT transfer disabled");
        vault.executeDecision(id);
        floor.set(0.5 ether, block.timestamp);
        vm.warp(vault.decisionDeadline(id));
        vault.settleFallback(id);
        _state(id, KeelSpinVault.State.Settled);
        assertEq(pool.stuckNFTRecipient(vault.rounds(id).listingId), depositor);
    }

    function testSaleProceedsProRataOnceIncludingBuffer() public {
        uint256 target = vault.liveTarget();
        _bet(alice, target / 4);
        _bet(bob, target * 3 / 4);
        _spin(1);
        _allocate(1);
        floor.set(30 ether, block.timestamp);
        vault.requestDecision(1);
        uint256 buffer = vault.rounds(1).cash;
        vm.deal(team, 10 ether);
        vm.prank(team);
        vault.depositSaleProceeds{value: 4 ether}(1, keccak256("market sale"));
        _state(1, KeelSpinVault.State.Settled);
        assertEq(vault.claimable(1, alice), (4 ether + buffer) / 4);
        assertEq(vault.claimable(1, bob), (4 ether + buffer) * 3 / 4);
        vm.expectRevert(KeelSpinVault.WrongState.selector);
        vault.depositSaleProceeds{value: 1 ether}(1, keccak256("duplicate"));
        vm.prank(alice);
        vault.claim(1);
        vm.prank(bob);
        vault.claim(1);
        assertEq(address(vault).balance, 0);
        assertEq(vault.accountedETH(), 0);
        vm.prank(alice);
        vm.expectRevert(KeelSpinVault.InvalidAmount.selector);
        vault.claim(1);
    }

    function testUnauthorizedAndInvalidSaleProceedsRejected() public {
        uint256 id = _ready();
        floor.set(30 ether, block.timestamp);
        vault.requestDecision(id);
        vm.prank(alice);
        vm.expectRevert(KeelSpinVault.NotSaleOperator.selector);
        vault.depositSaleProceeds{value: 1 ether}(id, keccak256("sale"));
        vm.expectRevert(KeelSpinVault.InvalidAmount.selector);
        vault.depositSaleProceeds(id, keccak256("sale"));
        vm.expectRevert(KeelSpinVault.InvalidAmount.selector);
        vault.depositSaleProceeds{value: 1 ether}(id, bytes32(0));
        vm.prank(alice);
        vm.expectRevert(KeelSpinVault.WrongState.selector);
        vault.claim(id);
    }

    function testSaleRequiresSuccessfulNFTForward() public {
        RejectNFT recipient = new RejectNFT();
        vault.setTeamWallet(address(recipient));
        uint256 id = _ready();
        floor.set(30 ether, block.timestamp);
        vault.requestDecision(id);
        vm.expectRevert(KeelSpinVault.WrongState.selector);
        vault.depositSaleProceeds{value: 1 ether}(id, keccak256("sale"));
    }

    function testFeeCapAndFeeExcludesBuffer() public {
        vm.expectRevert(KeelSpinVault.InvalidParameter.selector);
        vault.setFeeBps(301);
        vault.setFeeBps(300);
        (uint256 id,) = _ask();
        _answer(id, 0);
        uint256 buffer = vault.rounds(id).cash;
        vault.executeDecision(id);
        assertEq(vault.feeCredit(team), 0.027 ether);
        assertEq(vault.claimable(id, alice), buffer + 0.873 ether);
        uint256 beforeBalance = team.balance;
        vm.prank(team);
        vault.claimFees(payable(team));
        assertEq(team.balance - beforeBalance, 0.027 ether);
        vm.prank(alice);
        vault.claim(id);
        assertEq(address(vault).balance, 0);
    }

    function testFeeCannotBeChangedForExistingBettors() public {
        uint256 id = _fund();
        vault.setFeeBps(300);
        _spin(id);
        _allocate(id);
        floor.set(0.5 ether, block.timestamp);
        _fallback(id);
        assertEq(vault.feeCredit(team), 0);
        assertEq(vault.rounds(id).fee, 0);
        assertEq(vault.rounds(vault.currentRoundId()).fee, 300);
    }

    function testSaleFeeAndRoundingDustAllStayAccounted() public {
        vault.setFeeBps(137);
        uint256 target = vault.liveTarget();
        _bet(alice, target / 3);
        _bet(bob, target - target / 3);
        _spin(1);
        _allocate(1);
        floor.set(30 ether, block.timestamp);
        vault.requestDecision(1);
        vault.depositSaleProceeds{value: 1 ether + 7}(1, keccak256("sale"));
        uint256 expectedFee = uint256(1 ether + 7) * 137 / 10000;
        assertEq(vault.feeCredit(team), expectedFee);
        vm.prank(bob);
        vault.claim(1);
        vm.prank(alice);
        vault.claim(1);
        assertEq(address(vault).balance, expectedFee);
        assertEq(vault.rounds(1).cash, 0);
        vm.prank(team);
        vault.claimFees(payable(team));
        assertEq(address(vault).balance, 0);
    }

    function testStrandedKeptNFTReleasesCashAfterGraceAndStaysForwardable() public {
        RejectNFT recipient = new RejectNFT();
        vault.setTeamWallet(address(recipient));
        uint256 id = _ready();
        floor.set(30 ether, block.timestamp);
        vault.requestDecision(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        // The collection now halts transfers out of the vault for good.
        nft.setRejectTransfers(true);
        vault.forwardNFT(id);
        assertEq(nft.ownerOf(1), address(vault));
        assertFalse(vault.rounds(id).nftForwarded);
        uint256 buffer = vault.rounds(id).cash;
        uint256 grace = vault.rounds(id).allocatedAt + 30 days;
        vm.warp(grace - 1);
        assertFalse(vault.nftStranded(id));
        vm.expectRevert(KeelSpinVault.WrongState.selector);
        vault.depositSaleProceeds{value: 1}(id, keccak256("stranded"));
        vm.warp(grace);
        assertTrue(vault.nftStranded(id));
        vault.depositSaleProceeds{value: 1}(id, keccak256("stranded"));
        _state(id, KeelSpinVault.State.Settled);
        assertEq(vault.claimable(id, alice), buffer + 1);
        vm.prank(alice);
        vault.claim(id);
        nft.setRejectTransfers(false);
        recipient.setReject(false);
        vault.forwardNFT(id);
        assertEq(nft.ownerOf(1), address(recipient));
        assertTrue(vault.rounds(id).nftForwarded);
        assertFalse(vault.nftStranded(id));
        _solvent();
    }

    function testStuckKeptNFTRemainsRecoverableAfterStrandedSettlement() public {
        uint256 id = _ready();
        // FWA's best-effort delivery fails: the NFT stays in the pool, owed to the vault.
        nft.setRejectTransfers(true);
        vm.warp(block.timestamp + pool.settlementWindow());
        uint256 listing = vault.rounds(id).listingId;
        pool.finalizeUnsettled(listing);
        vault.syncRound(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertTrue(vault.rounds(id).kept);
        assertFalse(vault.rounds(id).nftForwarded);
        assertEq(pool.stuckNFTRecipient(listing), address(vault));
        uint256 buffer = vault.rounds(id).cash;
        // The team settles the round through the stranded path once the grace period has passed.
        vm.warp(uint256(vault.rounds(id).allocatedAt) + 30 days);
        assertTrue(vault.nftStranded(id));
        vm.deal(team, 1 ether);
        vm.prank(team);
        vault.depositSaleProceeds{value: 1}(id, keccak256("stranded"));
        _state(id, KeelSpinVault.State.Settled);
        assertEq(vault.claimable(id, alice), buffer + 1);
        // While the collection still rejects, the pool's recovery reverts and nothing is marked forwarded.
        vm.expectRevert("NFT transfer disabled");
        vault.recoverStuckNFT(id);
        // Once it transfers again, the vault (the only address FWA lets pull the token) recovers and forwards it.
        nft.setRejectTransfers(false);
        vault.recoverStuckNFT(id);
        assertEq(pool.stuckNFTRecipient(listing), address(0));
        assertEq(nft.ownerOf(1), team, "kept NFT is permanently stuck in the FWA pool");
        assertTrue(vault.rounds(id).nftForwarded);
        assertFalse(vault.nftStranded(id));
        // A repeated call has nothing to recover: the pool no longer owes the vault anything.
        vm.expectRevert("not stuck recipient");
        vault.recoverStuckNFT(id);
        vault.forwardNFT(id);
        assertEq(nft.ownerOf(1), team);
        _solvent();
    }

    function testRecoverStuckNFTRejectsEthSettledRound() public {
        uint256 id = _ready();
        floor.set(0.5 ether, block.timestamp);
        _fallback(id);
        _state(id, KeelSpinVault.State.Settled);
        assertFalse(vault.rounds(id).kept);
        vm.expectRevert(KeelSpinVault.WrongState.selector);
        vault.recoverStuckNFT(id);
    }

    function testForwardNFTRejectsEthSettledRound() public {
        uint256 id = _ready();
        floor.set(0.5 ether, block.timestamp);
        _fallback(id);
        _state(id, KeelSpinVault.State.Settled);
        vm.expectRevert(KeelSpinVault.WrongState.selector);
        vault.forwardNFT(id);
    }

    function testFeeAppliesToBidNotUnsolicitedEth() public {
        vault.setFeeBps(300);
        uint256 id = _ready();
        uint256 buffer = vault.rounds(id).cash;
        (bool sent,) = address(vault).call{value: 1 ether}("");
        assertTrue(sent);
        floor.set(0.5 ether, block.timestamp);
        _fallback(id);
        assertEq(vault.feeCredit(team), 0.027 ether);
        assertEq(vault.claimable(id, alice), buffer + 1.9 ether - 0.027 ether);
        _solvent();
    }

    function testUnsolicitedEthCannotBeSweptAndBenefitsResolvingRound() public {
        uint256 id = _ready();
        uint256 buffer = vault.rounds(id).cash;
        (bool sent,) = address(vault).call{value: 0.2 ether}("");
        assertTrue(sent);
        floor.set(0.5 ether, block.timestamp);
        _fallback(id);
        assertEq(vault.claimable(id, alice), buffer + 1.1 ether);
        _solvent();
    }

    function testUnrelatedNFTCannotEnterSafeReceiver() public {
        nft.mint(alice, 999);
        vm.prank(alice);
        vm.expectRevert(KeelSpinVault.UnexpectedNFT.selector);
        nft.safeTransferFrom(alice, address(vault), 999);
    }
}
