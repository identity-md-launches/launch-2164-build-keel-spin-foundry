// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelBase} from "./KeelBase.t.sol";
import {KeelSpinVault} from "../src/KeelSpinVault.sol";
import {KeelFwaRouter} from "../src/KeelFwaRouter.sol";
import {MockFWA} from "./mocks/Protocols.sol";

contract KeelRoundsTest is KeelBase {
    function testCarryOverAndWithdraw() public {
        uint256 target = vault.liveTarget();
        _bet(alice, target + 0.01 ether);
        assertEq(vault.stake(1, alice), target);
        assertEq(vault.stake(2, alice), 0.01 ether);
        _state(1, KeelSpinVault.State.Open);
        _state(2, KeelSpinVault.State.Open);
        uint256 beforeBalance = alice.balance;
        vm.prank(alice);
        vault.withdraw(1);
        assertEq(alice.balance - beforeBalance, target);
        assertEq(vault.rounds(1).bettors, 0);
        _solvent();
    }

    function testMultipleRoundCarryOver() public {
        uint256 target = vault.liveTarget();
        _bet(alice, target * 3 + 0.001 ether);
        assertEq(vault.roundCount(), 4);
        for (uint256 i = 1; i <= 3; ++i) {
            assertEq(vault.rounds(i).cash, target);
        }
        assertEq(vault.rounds(4).cash, 0.001 ether);
        _solvent();
    }

    function testHugeBetAtomicBound() public {
        uint256 amount = vault.liveTarget() * 33;
        vm.expectRevert(KeelSpinVault.TooManyRounds.selector);
        vault.bet{value: amount}();
        assertEq(vault.roundCount(), 1);
        assertEq(vault.accountedETH(), 0);
    }

    function testMinimumAppliesToTransactionNotCarryFragment() public {
        vm.expectRevert(KeelSpinVault.InvalidAmount.selector);
        vault.bet{value: 0.0009 ether}();
        uint256 target = vault.liveTarget();
        _bet(alice, target + 1);
        assertEq(vault.rounds(2).cash, 1);
    }

    function testPriceRiseKeepsRoundOpenAndTopUpUsesLivePrice() public {
        uint256 id = _fund();
        pool.setPrice(0.2 ether, 0.003 ether);
        vm.expectRevert(KeelSpinVault.InsufficientRoundBalance.selector);
        vault.spin(id);
        _state(id, KeelSpinVault.State.Open);
        uint256 amount = vault.liveTarget() - vault.rounds(id).cash;
        vm.prank(bob);
        vault.betInto{value: amount}(id);
        _spin(id);
        _state(id, KeelSpinVault.State.Spinning);
        _solvent();
    }

    function testPriceRiseInVrfFeeUsesTransactionGasPrice() public {
        pool.setGasUnits(1000000);
        uint256 id = _fund();
        vm.txGasPrice(50 gwei);
        vm.expectRevert(KeelSpinVault.InsufficientRoundBalance.selector);
        vault.spin(id);
        _state(id, KeelSpinVault.State.Open);
    }

    function testGasCap() public {
        uint256 id = _fund();
        vm.txGasPrice(vault.maxSpinGasPrice() + 1);
        vm.expectRevert(KeelSpinVault.GasPriceTooHigh.selector);
        vault.spin(id);
        _state(id, KeelSpinVault.State.Open);
    }

    function testSpinRewardAndRouterGuards() public {
        vault.setSpinParameters(0.002 ether, 100 gwei, 123456, 450);
        uint256 id = _fund();
        uint256 beforeBalance = keeper.balance;
        _spin(id);
        assertEq(keeper.balance - beforeBalance, 0.002 ether);
        assertEq(pool.lastBuilder(), address(router));
        assertEq(pool.lastMaxFee(), 0.1 ether);
        assertEq(pool.lastMinWeighted(), 123456);
        assertEq(pool.lastSlippage(), 450);
        assertEq(pool.acquisitions(vault.rounds(id).requestId).purchaser, address(vault));
        vm.expectRevert(KeelFwaRouter.OnlyVault.selector);
        router.purchase{value: 1 ether}(1 ether, 0, 0);
    }

    function testRewardClampsToTwoPercent() public {
        pool.setPrice(0.01 ether, 0);
        uint256 id = _fund();
        uint256 beforeBalance = keeper.balance;
        _spin(id);
        assertEq(keeper.balance - beforeBalance, 0.0002 ether);
    }

    function testBufferAndImmediateRefundBelongToBettors() public {
        pool.setRebate(0.005 ether);
        vm.deal(address(router), 7 ether);
        uint256 id = _fund();
        uint256 funded = vault.rounds(id).cash;
        _spin(id);
        assertEq(vault.rounds(id).cash, funded - 0.098 ether - 0.002 ether);
        assertEq(address(router).balance, 7 ether);
        _allocate(id);
        floor.set(0.5 ether, block.timestamp);
        _fallback(id);
        uint256 payout = funded - 0.098 ether - 0.002 ether + 0.9 ether;
        assertEq(vault.claimable(id, alice), payout);
        vm.prank(alice);
        vault.claim(id);
        assertEq(address(vault).balance, 0);
        _solvent();
    }

    function testBlackoutBothDailyWindowsAndBoundaries() public {
        uint256 id = _fund();
        uint256 day = block.timestamp / 1 days * 1 days;
        vm.warp(day + 11 hours + 45 minutes);
        vm.expectRevert(KeelSpinVault.Blackout.selector);
        vault.spin(id);
        vm.warp(day + 23 hours + 45 minutes);
        vm.expectRevert(KeelSpinVault.Blackout.selector);
        vault.spin(id);
        vm.warp(day + 1 days - 1);
        vm.expectRevert(KeelSpinVault.Blackout.selector);
        vault.spin(id);
        vm.warp(day + 1 days);
        _spin(id);
    }

    function testNoonBoundaryAllowsSpin() public {
        uint256 id = _fund();
        vm.warp(block.timestamp / 1 days * 1 days + 12 hours);
        _spin(id);
    }

    function testProtocolBlackoutAlsoChecked() public {
        uint256 id = _fund();
        pool.setBlackout(true);
        vm.expectRevert(KeelSpinVault.Blackout.selector);
        vault.spin(id);
    }

    function testRefundReopensRoundAndSharesVrfAndRewardLoss() public {
        uint256 target = vault.liveTarget();
        _bet(alice, target / 4);
        _bet(bob, target * 3 / 4);
        _spin(1);
        pool.refund(vault.rounds(1).requestId, false);
        vault.syncRound(1);
        _state(1, KeelSpinVault.State.Open);
        assertEq(vault.activeRoundId(), 0);
        assertEq(vault.rounds(1).cash, target - 0.003 ether - 0.002 ether);
        assertEq(vault.withdrawable(1, alice), (target - 0.005 ether) / 4);
        vm.prank(alice);
        vault.withdraw(1);
        vm.prank(bob);
        vault.withdraw(1);
        assertEq(address(vault).balance, 0);
        _solvent();
        vm.expectRevert(KeelSpinVault.WrongState.selector);
        vault.syncRound(1);
    }

    function testExpiredRequestRefundAndRetry() public {
        uint256 id = _fund();
        _spin(id);
        uint256 oldRequest = vault.rounds(id).requestId;
        pool.setStatus(oldRequest, 6);
        vault.syncRound(id);
        _state(id, KeelSpinVault.State.Spinning);
        pool.refund(oldRequest, true);
        vault.syncRound(id);
        uint256 amount = vault.liveTarget() - vault.rounds(id).cash;
        vm.prank(bob);
        vault.betInto{value: amount}(id);
        // A new participant cannot take the old participant's fee loss or inherit it.
        assertApproxEqAbs(vault.withdrawable(id, bob), amount, 1);
        _spin(id);
        assertGt(vault.rounds(id).requestId, oldRequest);
        _allocate(id);
        floor.set(30 ether, block.timestamp);
        vault.requestDecision(id);
        _state(id, KeelSpinVault.State.AwaitingSale);
        _solvent();
    }

    function testOnlyOneUnresolvedRequestButNextRoundCanCollect() public {
        _bet(alice, vault.liveTarget() * 2);
        _spin(1);
        vm.expectRevert(KeelSpinVault.SpinInProgress.selector);
        vault.spin(2);
        _allocate(1);
        floor.set(30 ether, block.timestamp);
        vault.requestDecision(1);
        _spin(2);
        _state(1, KeelSpinVault.State.AwaitingSale);
        _state(2, KeelSpinVault.State.Spinning);
    }

    function testPauseOnlyStopsBets() public {
        uint256 id = _fund();
        vault.setBetsPaused(true);
        vm.expectRevert(KeelSpinVault.Paused.selector);
        vault.bet{value: 0.01 ether}();
        vm.prank(alice);
        vault.withdraw(id);
        vault.setBetsPaused(false);
        id = _fund();
        vault.setBetsPaused(true);
        _spin(id);
    }

    function testAcquireFailureRollsBackAllAccountingAndReward() public {
        uint256 id = _fund();
        uint256 beforeBalance = keeper.balance;
        pool.setFailures(true, false);
        vm.expectRevert("acquisition disabled");
        vault.spin(id);
        _state(id, KeelSpinVault.State.Open);
        assertEq(vault.activeRoundId(), 0);
        assertEq(keeper.balance, beforeBalance);
        assertEq(vault.rounds(id).cash, vault.liveTarget());
        _solvent();
    }

    function testPendingRequestCannotWithdrawClaimOrDecide() public {
        uint256 id = _fund();
        _spin(id);
        vm.expectRevert(KeelSpinVault.WrongState.selector);
        vault.withdraw(id);
        vm.expectRevert(KeelSpinVault.WrongState.selector);
        vault.claim(id);
        vm.expectRevert(KeelSpinVault.WrongState.selector);
        vault.requestDecision(id);
        vm.expectRevert(KeelSpinVault.WrongState.selector);
        vault.betInto{value: 0.01 ether}(id);
        pool.setStatus(vault.rounds(id).requestId, 5);
        vault.syncRound(id);
        _state(id, KeelSpinVault.State.Spinning);
    }

    function testDependenciesCannotBeReplacedUnderExistingBets() public {
        _fund();
        vm.expectRevert(KeelSpinVault.OutstandingBets.selector);
        vault.setFwa(address(pool));
        vm.expectRevert(KeelSpinVault.OutstandingBets.selector);
        vault.setRouter(address(router));
        vm.expectRevert(KeelFwaRouter.OutstandingBets.selector);
        router.setPool(address(pool));
    }

    function testFuzzUpTo500BettorsAndProRataConservation(uint16 countSeed, uint64 amountSeed) public {
        uint256 count = bound(countSeed, 1, 500);
        uint256 each = bound(uint256(amountSeed), 0.001 ether, 0.01 ether);
        uint256 total = count * each;
        pool.setPrice(total, 0);
        for (uint256 i; i < count; ++i) {
            address bettor = address(uint160(0x10000 + i));
            vm.deal(bettor, each);
            _bet(bettor, each);
        }
        assertEq(vault.rounds(1).bettors, count);
        assertEq(vault.rounds(1).cash, total);
        for (uint256 i; i < count; ++i) {
            address bettor = address(uint160(0x10000 + i));
            vm.prank(bettor);
            vault.withdraw(1);
            assertEq(bettor.balance, each);
        }
        assertEq(vault.totalSharesOutstanding(), 0);
        assertEq(address(vault).balance, 0);
    }

    function test501stBettorCarriedToNextRound() public {
        pool.setPrice(1 ether, 0);
        for (uint256 i; i < 501; ++i) {
            address bettor = address(uint160(0x20000 + i));
            vm.deal(bettor, 0.001 ether);
            _bet(bettor, 0.001 ether);
        }
        assertEq(vault.rounds(1).bettors, 500);
        assertEq(vault.rounds(2).bettors, 1);
        assertEq(vault.rounds(1).cash, 0.5 ether);
        _solvent();
    }

    function testFuzzUpTo500SettledBettors(uint16 countSeed, uint32 weightSeed) public {
        uint256 count = bound(countSeed, 1, 500);
        uint256 unit = bound(uint256(weightSeed), 1, 0.00001 ether);
        uint256[] memory amounts = new uint256[](count);
        uint256 total;
        for (uint256 i; i < count; ++i) {
            amounts[i] = 0.001 ether + ((i + weightSeed) % 17) * unit;
            total += amounts[i];
        }
        vault.setBetParameters(0.001 ether, 500, 10000);
        vault.setFeeBps(137);
        pool.setPrice(total * 9 / 10, 0);
        for (uint256 i; i < count; ++i) {
            address bettor = address(uint160(0x30000 + i));
            vm.deal(bettor, amounts[i]);
            _bet(bettor, amounts[i]);
        }
        assertEq(vault.roundCount(), 1);
        assertEq(vault.rounds(1).bettors, count);
        _spin(1);
        _allocate(1);
        floor.set(0.5 ether, block.timestamp);
        _fallback(1);
        uint256 distributable = vault.rounds(1).cash;
        uint256 paid;
        // Reverse claim order exercises the final-claim rounding remainder with unequal stakes.
        for (uint256 i = count; i != 0;) {
            --i;
            address bettor = address(uint160(0x30000 + i));
            uint256 beforeBalance = bettor.balance;
            vm.prank(bettor);
            vault.claim(1);
            uint256 amount = bettor.balance - beforeBalance;
            assertApproxEqAbs(amount, distributable * amounts[i] / total, count);
            paid += amount;
        }
        assertEq(paid, distributable);
        assertEq(vault.rounds(1).cash, 0);
        assertEq(vault.totalSharesOutstanding(), 0);
        assertEq(address(vault).balance, vault.feeCredit(team));
        vm.prank(team);
        vault.claimFees(payable(team));
        assertEq(address(vault).balance, 0);
        _solvent();
    }
}
