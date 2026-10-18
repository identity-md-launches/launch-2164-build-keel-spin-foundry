// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelBase} from "./KeelBase.t.sol";
import {KeelSpinVault} from "../src/KeelSpinVault.sol";
import {KeelFwaRouter} from "../src/KeelFwaRouter.sol";
import {MockFWA, RejectNFT} from "./mocks/Protocols.sol";

/// Independent checks of the revision that introduced unresolvedShares, minOracleLead,
/// policy locks during a spin and the stranded-NFT release.
contract KeelRevisionChecksTest is KeelBase {
    function _openShares() internal view returns (uint256 total) {
        for (uint256 id = 1; id <= vault.roundCount(); ++id) {
            KeelSpinVault.Round memory r = vault.rounds(id);
            if (r.state != KeelSpinVault.State.AwaitingSale && r.state != KeelSpinVault.State.Settled) {
                total += r.totalShares;
            }
        }
    }

    function testRefundedRoundStakeStaysUnresolvedAndBlocksMigration() public {
        uint256 id = _fund();
        uint256 shares = vault.rounds(id).totalShares;
        _spin(id);
        assertEq(vault.unresolvedShares(), shares);
        pool.refund(vault.rounds(id).requestId, false);
        vault.syncRound(id);
        _state(id, KeelSpinVault.State.Open);
        assertEq(vault.activeRoundId(), 0);
        // Back to Open: the bettors still depend on the FWA wiring, so nothing may migrate under them.
        assertEq(vault.unresolvedShares(), shares);
        MockFWA newPool = new MockFWA();
        vm.expectRevert(KeelSpinVault.OutstandingBets.selector);
        vault.setFwa(address(newPool));
        vm.expectRevert(KeelFwaRouter.OutstandingBets.selector);
        router.setPool(address(newPool));
        vm.prank(alice);
        vault.withdraw(id);
        assertEq(vault.unresolvedShares(), 0);
        assertEq(vault.totalSharesOutstanding(), 0);
        vault.setFwa(address(newPool));
        _solvent();
    }

    function testSpinningRoundBlocksMigrationEvenWithNoOtherStake() public {
        uint256 id = _fund();
        _spin(id);
        MockFWA newPool = new MockFWA();
        vm.expectRevert(KeelSpinVault.OutstandingBets.selector);
        vault.setFwa(address(newPool));
        vm.expectRevert(KeelFwaRouter.OutstandingBets.selector);
        router.setPool(address(newPool));
    }

    function testStuckNftInOldPoolRecoverableAfterMigration() public {
        uint256 id = _ready();
        uint256 listingId = vault.rounds(id).listingId;
        nft.setRejectTransfers(true);
        vm.warp(block.timestamp + pool.settlementWindow());
        pool.finalizeUnsettled(listingId);
        vault.syncRound(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertEq(vault.unresolvedShares(), 0);
        // The owner migrates to a new pool while the old pool still holds the kept NFT.
        MockFWA newPool = new MockFWA();
        KeelFwaRouter newRouter = new KeelFwaRouter(address(this), address(vault), address(newPool));
        vault.setFwa(address(newPool));
        vault.setRouter(address(newRouter));
        nft.setRejectTransfers(false);
        vault.recoverStuckNFT(id);
        assertEq(nft.ownerOf(1), team);
        uint256 buffer = vault.rounds(id).cash;
        vm.deal(team, 3 ether);
        vm.prank(team);
        vault.depositSaleProceeds{value: 2 ether}(id, keccak256("sale"));
        assertEq(vault.claimable(id, alice), buffer + 2 ether);
        // A second deposit for the same round is refused.
        vm.prank(team);
        vm.expectRevert(KeelSpinVault.WrongState.selector);
        vault.depositSaleProceeds{value: 1 ether}(id, keccak256("sale2"));
        _solvent();
    }

    function testStrandedReleaseRequiresOperatorAndNonZeroDeposit() public {
        RejectNFT recipient = new RejectNFT();
        vault.setTeamWallet(address(recipient));
        uint256 id = _ready();
        floor.set(30 ether, block.timestamp);
        vault.requestDecision(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertEq(nft.ownerOf(1), address(vault));
        vm.warp(uint256(vault.rounds(id).allocatedAt) + 30 days);
        assertTrue(vault.nftStranded(id));
        vm.prank(alice);
        vm.expectRevert(KeelSpinVault.NotSaleOperator.selector);
        vault.depositSaleProceeds{value: 1 ether}(id, keccak256("stranded"));
        vm.deal(address(recipient), 1 ether);
        vm.startPrank(address(recipient));
        vm.expectRevert(KeelSpinVault.InvalidAmount.selector);
        vault.depositSaleProceeds(id, keccak256("stranded"));
        vm.expectRevert(KeelSpinVault.InvalidAmount.selector);
        vault.depositSaleProceeds{value: 1}(id, bytes32(0));
        vm.stopPrank();
        // An ETH-settled round never becomes stranded, whatever the clock says.
        floor.set(0.5 ether, block.timestamp);
        uint256 other = _ready();
        _fallback(other);
        _state(other, KeelSpinVault.State.Settled);
        vm.warp(block.timestamp + 31 days);
        assertFalse(vault.nftStranded(other));
    }

    function testZeroOracleLeadAnswerAtCutoffIsRefusedAndFallsBack() public {
        // With the lead set to zero an ask one second before fallbackAt is still paid; its answer must
        // then land before the cutoff or be refused. (The ask at exactly fallbackAt is reported separately.)
        vault.setDecisionParameters(1500, 500, 24 hours, 10 minutes, 20 minutes, 0, true);
        uint256 id = _ready();
        vm.warp(vault.fallbackAt(id) - 1);
        vault.requestDecision(id);
        _state(id, KeelSpinVault.State.OraclePending);
        assertEq(intake.nonce(), 1);
        bytes32 requestId = vault.rounds(id).oracleRequestId;
        vm.warp(vault.fallbackAt(id));
        // An answer arriving at the cutoff is refused and the round falls back without it.
        assertFalse(intake.result(requestId, _attestation(5 ether), _sign(_attestation(5 ether))));
        vault.settleFallback(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        assertEq(vault.pending(requestId), 0);
    }

    function testDecisionTimingMustStayStrictlyInsideWindow() public {
        uint256 window = pool.settlementWindow();
        vm.expectRevert(KeelSpinVault.InvalidParameter.selector);
        vault.setDecisionParameters(1500, 500, 24 hours, window, 0, 0, true);
        vm.expectRevert(KeelSpinVault.InvalidParameter.selector);
        vault.setDecisionParameters(1500, 500, 24 hours, 0, 0, window, true);
        vm.expectRevert(KeelSpinVault.InvalidParameter.selector);
        vault.setDecisionParameters(1500, 500, 0, 0, 0, 0, true);
        vault.setDecisionParameters(1500, 500, 24 hours, window - 1, 0, 0, true);
        assertEq(vault.safetyMargin(), window - 1);
        vm.prank(alice);
        vm.expectRevert();
        vault.setDecisionParameters(1500, 500, 24 hours, 0, 0, 0, true);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzzUnresolvedSharesTracksNonTerminalStake(uint256 seed, uint8 countSeed) public {
        uint256 count = bound(countSeed, 1, 60);
        uint256 target = vault.liveTarget();
        for (uint256 i; i < count; ++i) {
            address bettor = address(uint160(0x10000 + i));
            uint256 amount = bound(uint256(keccak256(abi.encode(seed, i))), 0.001 ether, target);
            vm.deal(bettor, amount);
            vm.prank(bettor);
            vault.bet{value: amount}();
            assertEq(vault.unresolvedShares(), _openShares(), "bet");
            if (uint256(keccak256(abi.encode(seed, i, "w"))) % 4 == 0) {
                uint256 id = vault.currentRoundId();
                if (vault.stake(id, bettor) != 0) {
                    vm.prank(bettor);
                    vault.withdraw(id);
                    assertEq(vault.unresolvedShares(), _openShares(), "withdraw");
                }
            }
        }
        // Resolve the first round if it is fundable, then claim it out.
        uint256 first = 1;
        if (vault.rounds(first).cash >= target && vault.rounds(first).totalShares != 0) {
            _spin(first);
            _allocate(first);
            floor.set(seed % 2 == 0 ? 30 ether : 0.5 ether, block.timestamp);
            vault.requestDecision(first);
            assertEq(vault.unresolvedShares(), _openShares(), "resolve");
            if (vault.rounds(first).state == KeelSpinVault.State.Settled) {
                for (uint256 i; i < count; ++i) {
                    address bettor = address(uint160(0x10000 + i));
                    if (vault.stake(first, bettor) != 0) {
                        vm.prank(bettor);
                        vault.claim(first);
                    }
                }
                assertEq(vault.rounds(first).totalShares, 0);
            }
            assertEq(vault.unresolvedShares(), _openShares(), "claim");
        }
        assertLe(vault.unresolvedShares(), vault.totalSharesOutstanding());
        _solvent();
    }
}
