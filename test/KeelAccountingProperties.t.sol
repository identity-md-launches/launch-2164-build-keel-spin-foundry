// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelBase} from "./KeelBase.t.sol";
import {KeelSpinVault} from "src/KeelSpinVault.sol";

contract KeelAccountingPropertiesTest is KeelBase {
    /// forge-config: default.fuzz.runs = 512
    function testFuzzRefundedShareRoundTripsCannotProfit(uint96 amountSeed, uint8 cyclesSeed) public {
        vault.setBetParameters(1, 500, 500);
        uint256 id = _fund();
        uint256 initialStake = vault.stake(id, alice);
        _spin(id);
        pool.refund(vault.rounds(id).requestId, false);
        vault.syncRound(id);
        uint256 originalValue = vault.withdrawable(id, alice);
        uint256 startingBalance = bob.balance;
        uint256 amount = bound(amountSeed, 1, 0.004 ether);
        uint256 cycles = bound(cyclesSeed, 1, 64);
        for (uint256 i; i < cycles; ++i) {
            vm.prank(bob);
            vault.betInto{value: amount}(id);
            assertLe(vault.withdrawable(id, bob), amount, "entrant extracted a prior bettor's refund");
            vm.prank(bob);
            vault.withdraw(id);
            assertLe(bob.balance, startingBalance, "repeated rounding cycle generated profit");
            assertGe(vault.withdrawable(id, alice), originalValue, "round trip diluted old bettor");
            assertEq(vault.stake(id, alice), initialStake);
            assertEq(vault.rounds(id).bettors, 1);
        }
        uint256 remaining = address(vault).balance;
        uint256 beforeAlice = alice.balance;
        vm.prank(alice);
        vault.withdraw(id);
        assertEq(alice.balance - beforeAlice, remaining);
        assertEq(address(vault).balance, 0);
        assertEq(vault.totalSharesOutstanding(), 0);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzzUpTo500BettorsRefundExitRefillAndShuffledClaims(
        uint16 countSeed,
        uint256 weightsSeed,
        uint16 feeSeed,
        uint16 orderSeed
    ) public {
        uint256 count = bound(countSeed, 2, 500);
        uint256 fee = bound(feeSeed, 0, 300);
        uint256[] memory stakesBefore = new uint256[](count);
        uint256 total;
        for (uint256 i; i < count; ++i) {
            stakesBefore[i] = 0.001 ether + uint256(keccak256(abi.encode(weightsSeed, i))) % 0.009 ether;
            total += stakesBefore[i];
        }
        // Exact funding allows us to measure the VRF loss independently of buffers/rewards.
        vault.setBetParameters(0.001 ether, 500, 0);
        vault.setSpinParameters(0, 100 gwei, 0, 500);
        vault.setFeeBps(uint16(fee));
        uint256 vrfCost = total / 10;
        pool.setPrice(total - vrfCost, vrfCost);
        for (uint256 i; i < count; ++i) {
            address actor = _actor(i);
            vm.deal(actor, stakesBefore[i]);
            _bet(actor, stakesBefore[i]);
        }
        assertEq(vault.rounds(1).bettors, count);
        _spin(1);
        pool.refund(vault.rounds(1).requestId, true);
        vault.syncRound(1);
        assertEq(address(vault).balance, total - vrfCost);
        for (uint256 i; i < count; ++i) {
            uint256 value = vault.withdrawable(1, _actor(i));
            assertApproxEqAbs(
                value, stakesBefore[i] - stakesBefore[i] * vrfCost / total, 1, "VRF cost not shared by original bettors"
            );
        }
        vm.prank(_actor(0));
        vault.withdraw(1);
        assertEq(vault.rounds(1).bettors, count - 1);
        uint256 topUp = total - vault.rounds(1).cash;
        address replacement = _actor(count);
        vm.deal(replacement, topUp);
        vm.prank(replacement);
        vault.betInto{value: topUp}(1);
        assertApproxEqAbs(vault.withdrawable(1, replacement), topUp, 1, "new bettor inherited old VRF costs");
        assertEq(vault.rounds(1).bettors, count);
        assertEq(vault.stake(1, _actor(0)), 0);
        _spin(1);
        _allocate(1);
        floor.set(0.5 ether, block.timestamp);
        _fallback(1);
        uint256 expectedFee = 0.9 ether * fee / 10000;
        assertEq(vault.feeCredit(team), expectedFee);
        uint256 distributable = 0.9 ether - expectedFee;
        assertEq(vault.rounds(1).cash, distributable);
        uint256 totalShares = vault.rounds(1).totalShares;
        uint256[] memory expected = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            address actor = i == 0 ? replacement : _actor(i);
            expected[i] = distributable * vault.stake(1, actor) / totalShares;
        }
        uint256 paid;
        for (uint256 i; i < count; ++i) {
            uint256 index = (i + orderSeed) % count;
            address actor = index == 0 ? replacement : _actor(index);
            uint256 beforeBalance = actor.balance;
            vm.prank(actor);
            vault.claim(1);
            uint256 received = actor.balance - beforeBalance;
            assertApproxEqAbs(received, expected[index], count, "claim order changed economic entitlement");
            paid += received;
        }
        assertEq(paid, distributable, "claim rounding stranded ETH");
        assertEq(address(vault).balance, expectedFee);
        assertEq(vault.totalSharesOutstanding(), 0);
        if (expectedFee != 0) {
            vm.prank(team);
            vault.claimFees(payable(team));
        }
        assertEq(address(vault).balance, 0);
    }

    function testCapacityIsReleasedAndExistingBettorCanTopUpAt500() public {
        pool.setPrice(2 ether, 0);
        for (uint256 i; i < 500; ++i) {
            vm.deal(_actor(i), 0.002 ether);
            _bet(_actor(i), 0.001 ether);
        }
        _bet(_actor(499), 0.001 ether);
        assertEq(vault.roundCount(), 1);
        assertEq(vault.rounds(1).bettors, 500);
        vm.prank(_actor(0));
        vault.withdraw(1);
        _bet(alice, 0.001 ether);
        assertEq(vault.roundCount(), 1);
        assertEq(vault.rounds(1).bettors, 500);
        _bet(bob, 0.001 ether);
        assertEq(vault.roundCount(), 2);
        assertEq(vault.stake(2, bob), 0.001 ether);
    }

    function testConcurrentSaleRefundAndOpenRoundBalancesStayIsolated() public {
        vault.setFeeBps(300);
        uint256 first = _ready();
        floor.set(30 ether, block.timestamp);
        vault.requestDecision(first);
        uint256 firstBuffer = vault.rounds(first).cash;
        uint256 second = _fund();
        uint256 secondFunded = vault.rounds(second).cash;
        _spin(second);
        _bet(bob, 0.02 ether);
        uint256 third = vault.currentRoundId();
        pool.refund(vault.rounds(second).requestId, false);
        vault.depositSaleProceeds{value: 3 ether}(first, keccak256("first sale"));
        vault.syncRound(second);
        assertEq(vault.claimable(first, alice), firstBuffer + 2.91 ether);
        assertEq(vault.withdrawable(second, alice), secondFunded - 0.005 ether);
        assertEq(vault.withdrawable(third, bob), 0.02 ether);
        vm.prank(alice);
        vault.claim(first);
        vm.prank(alice);
        vault.withdraw(second);
        vm.prank(bob);
        vault.withdraw(third);
        assertEq(address(vault).balance, 0.09 ether);
        vm.prank(team);
        vault.claimFees(payable(team));
        assertEq(address(vault).balance, 0);
    }

    function testTeamRotationCannotRedirectAlreadyAccruedFeeCredits() public {
        vault.setFeeBps(300);
        uint256 first = _ready();
        vault.setTeamWallet(bob);
        floor.set(0.5 ether, block.timestamp);
        _fallback(first);
        assertEq(vault.feeCredit(team), 0.027 ether);
        assertEq(vault.feeCredit(bob), 0);
        vm.prank(bob);
        vm.expectRevert(KeelSpinVault.InvalidAmount.selector);
        vault.claimFees(payable(bob));
        vm.prank(team);
        vault.claimFees(payable(team));
        uint256 next = _ready();
        floor.set(0.5 ether, block.timestamp);
        _fallback(next);
        assertEq(vault.feeCredit(bob), 0.027 ether);
        assertEq(vault.feeCredit(team), 0);
        vm.prank(alice);
        vault.claim(first);
        vm.prank(alice);
        vault.claim(next);
        vm.prank(bob);
        vault.claimFees(payable(bob));
        assertEq(address(vault).balance, 0);
    }

    function _actor(uint256 index) private pure returns (address) {
        return address(uint160(0x810000 + index));
    }
}
