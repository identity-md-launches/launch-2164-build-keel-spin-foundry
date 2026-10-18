// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeelBase} from "./KeelBase.t.sol";
import {KeelSpinVault} from "src/KeelSpinVault.sol";
import {KeelFwaRouter} from "src/KeelFwaRouter.sol";
import {MockFWA} from "./mocks/Protocols.sol";
import {LockedFWA, MockRewards, MockPermit2, MockTransferHelper} from "./mocks/BuilderRewards.sol";

contract BuilderHandler is Test {
    KeelSpinVault public vault;
    KeelFwaRouter public router;
    MockFWA public pool;
    LockedFWA public token;
    MockRewards public rewards;
    MockTransferHelper public helper;
    address public owner;
    address public team;
    address public bettor;
    uint256 public creditedAllowance;
    uint256 public convertedAllowance;
    uint256 public recoveredAllowance;
    uint256 public mintedTokens;
    uint256 public queues;
    uint256 public ethDonated;
    uint256 public ethPaidToTeam;
    uint256 public bets;
    uint256 public poolSpent;
    uint256 public poolRefunds;
    uint256 public spinRewards;
    uint256 public withdrawn;

    constructor(
        KeelSpinVault vault_,
        KeelFwaRouter router_,
        MockFWA pool_,
        LockedFWA token_,
        MockRewards rewards_,
        MockTransferHelper helper_
    ) {
        vault = vault_;
        router = router_;
        pool = pool_;
        token = token_;
        rewards = rewards_;
        helper = helper_;
        owner = router.owner();
        team = vault.teamWallet();
        bettor = makeAddr("builder-invariant-bettor");
    }

    function fundBettors() public {
        uint256 amount = vault.liveTarget() - vault.rounds(1).cash;
        if (amount == 0) return;
        vm.deal(bettor, bettor.balance + amount);
        vm.prank(bettor);
        vault.betInto{value: amount}(1);
        bets += amount;
    }

    function credit(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 0.1 ether);
        vm.deal(address(this), address(this).balance + amount);
        (bool ok,) = address(rewards).call{value: amount}("");
        assertTrue(ok);
        rewards.credit(address(router), amount);
        creditedAllowance += amount;
    }

    function mintHeld(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 100 ether);
        token.mint(address(router), amount);
        mintedTokens += amount;
    }

    function claimTokens(bool tooHigh) external {
        uint256 allowance = rewards.tokenBuyAllowance(address(router));
        if (allowance == 0) return;
        uint256 output = allowance * 1000;
        uint256 nonce = router.nextTransferNonce();
        uint256 held = token.balanceOf(address(router));
        if (tooHigh) {
            vm.prank(owner);
            vm.expectRevert("minimum output");
            router.claimBuilderRewards(output + 1, block.timestamp + 1 hours);
        } else if (!helper.enabled()) {
            vm.prank(owner);
            vm.expectRevert("helper disabled or wrong token");
            router.claimBuilderRewards(output, block.timestamp + 1 hours);
        } else {
            vm.prank(owner);
            assertEq(router.claimBuilderRewards(output, block.timestamp + 1 hours), output);
            convertedAllowance += allowance;
            mintedTokens += output;
            ++queues;
            // A claim queues only freshly purchased tokens, leaving pre-existing holdings intact.
            assertEq(token.balanceOf(address(router)), held);
            return;
        }
        assertEq(rewards.tokenBuyAllowance(address(router)), allowance, "failed claim destroyed allowance");
        assertEq(token.balanceOf(address(router)), held, "failed claim changed token custody");
        assertEq(router.nextTransferNonce(), nonce, "failed queue consumed nonce");
    }

    function queueHeld(uint256 amountSeed) public {
        uint256 held = token.balanceOf(address(router));
        if (held == 0) return;
        uint256 amount = bound(amountSeed, 1, held);
        uint256 nonce = router.nextTransferNonce();
        bool enabled = helper.enabled();
        vm.prank(owner);
        if (!enabled) {
            vm.expectRevert("helper disabled or wrong token");
            router.queueHeldBuilderRewards(amount, block.timestamp + 1 hours);
            assertEq(router.nextTransferNonce(), nonce);
            assertEq(token.balanceOf(address(router)), held);
        } else {
            router.queueHeldBuilderRewards(amount, block.timestamp + 1 hours);
            ++queues;
            assertEq(token.balanceOf(address(router)), held - amount);
        }
    }

    function claimFromHelper() public {
        uint256 amount = helper.claimable(team);
        if (amount == 0) return;
        if (block.number <= helper.depositedBlock(team)) {
            vm.expectRevert("next block");
            helper.claim(team);
            assertEq(helper.claimable(team), amount);
        } else {
            uint256 beforeBalance = token.balanceOf(team);
            helper.claim(team);
            assertEq(token.balanceOf(team) - beforeBalance, amount);
        }
    }

    function advanceBlock() public {
        vm.roll(block.number + 1);
    }

    function enableHelper(bool enabled) external {
        helper.setEnabled(enabled);
    }

    function donateETH(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 0.1 ether);
        vm.deal(address(this), address(this).balance + amount);
        (bool ok,) = address(router).call{value: amount}("");
        assertTrue(ok);
        ethDonated += amount;
    }

    function withdrawETH() public {
        uint256 beforeBalance = team.balance;
        vm.prank(owner);
        router.withdrawBuilderETH();
        ethPaidToTeam += team.balance - beforeBalance;
    }

    function recoverETH(bool emergency) external {
        rewards.setEmergency(emergency);
        uint256 allowance = rewards.tokenBuyAllowance(address(router));
        if (!emergency) {
            vm.prank(owner);
            vm.expectRevert("core not in emergency");
            router.recoverBuilderAllowanceAsETH();
            assertEq(rewards.tokenBuyAllowance(address(router)), allowance);
        } else {
            uint256 beforeBalance = team.balance;
            vm.prank(owner);
            assertEq(router.recoverBuilderAllowanceAsETH(), allowance);
            recoveredAllowance += allowance;
            ethPaidToTeam += team.balance - beforeBalance;
            assertEq(team.balance - beforeBalance, allowance);
        }
    }

    function spinAndRefund(uint256 rebateSeed, bool expired) external {
        fundBettors();
        pool.setRebate(bound(rebateSeed, 0, 0.01 ether));
        uint256 beforePool = address(pool).balance;
        uint256 beforeKeeper = address(this).balance;
        vault.spin(1);
        poolSpent += address(pool).balance - beforePool;
        spinRewards += address(this).balance - beforeKeeper;
        pool.refund(vault.rounds(1).requestId, expired);
        beforePool = address(pool).balance;
        vault.syncRound(1);
        poolRefunds += beforePool - address(pool).balance;
        assertEq(vault.activeRoundId(), 0);
    }

    function closeAll() external {
        helper.setEnabled(true);
        uint256 allowance = rewards.tokenBuyAllowance(address(router));
        if (allowance != 0) {
            vm.prank(owner);
            router.claimBuilderRewards(allowance * 1000, block.timestamp + 1 hours);
            convertedAllowance += allowance;
            mintedTokens += allowance * 1000;
            ++queues;
        }
        uint256 held = token.balanceOf(address(router));
        if (held != 0) queueHeld(held);
        advanceBlock();
        claimFromHelper();
        withdrawETH();
        uint256 beforeBalance = bettor.balance;
        vm.prank(bettor);
        vault.withdraw(1);
        withdrawn += bettor.balance - beforeBalance;
    }

    receive() external payable {}
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract KeelBuilderInvariantTest is KeelBase {
    LockedFWA internal token;
    MockRewards internal rewards;
    MockTransferHelper internal helper;
    BuilderHandler internal builder;

    function setUp() public override {
        super.setUp();
        token = new LockedFWA();
        rewards = new MockRewards(address(token), address(pool));
        helper = new MockTransferHelper(address(token));
        token.setDistributor(address(helper), true);
        pool.setRewards(address(rewards), address(token));
        router.setTransferHelper(address(helper));
        MockPermit2 permit = new MockPermit2();
        vm.etch(router.PERMIT2(), address(permit).code);
        builder = new BuilderHandler(vault, router, pool, token, rewards, helper);
        builder.fundBettors();
        targetContract(address(builder));
        targetSender(makeAddr("builder-invariant-driver"));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = builder.credit.selector;
        selectors[1] = builder.mintHeld.selector;
        selectors[2] = builder.claimTokens.selector;
        selectors[3] = builder.queueHeld.selector;
        selectors[4] = builder.claimFromHelper.selector;
        selectors[5] = builder.advanceBlock.selector;
        selectors[6] = builder.enableHelper.selector;
        selectors[7] = builder.donateETH.selector;
        selectors[8] = builder.withdrawETH.selector;
        selectors[9] = builder.recoverETH.selector;
        selectors[10] = builder.spinAndRefund.selector;
        targetSelector(FuzzSelector(address(builder), selectors));
    }

    function invariantBuilderAssetsStayWithRouterHelperOrTeam() public view {
        uint256 tokens = token.balanceOf(address(router)) + token.balanceOf(address(helper)) + token.balanceOf(team);
        assertEq(tokens, builder.mintedTokens());
        assertEq(token.totalSupply(), builder.mintedTokens());
        assertEq(helper.claimable(team), token.balanceOf(address(helper)));
        assertEq(token.balanceOf(address(vault)), 0, "bettor vault received locked FWA");
        assertEq(address(router).balance + builder.ethPaidToTeam(), builder.ethDonated() + builder.recoveredAllowance());
        assertEq(
            rewards.tokenBuyAllowance(address(router)) + builder.convertedAllowance() + builder.recoveredAllowance(),
            builder.creditedAllowance()
        );
    }

    function invariantBuilderOperationsCannotConsumeBettorEth() public view {
        assertEq(
            address(vault).balance + builder.poolSpent() + builder.spinRewards() + builder.withdrawn(),
            builder.bets() + builder.poolRefunds()
        );
        assertEq(vault.accountedETH(), address(vault).balance);
        assertEq(vault.withdrawable(1, builder.bettor()), address(vault).balance);
        assertEq(vault.activeRoundId(), 0);
    }

    function invariantEverySuccessfulQueueConsumesExactlyOneScopedPermit() public {
        assertEq(router.nextTransferNonce(), builder.queues());
        for (uint256 i; i < builder.queues(); ++i) {
            assertTrue(MockPermit2(router.PERMIT2()).used(address(router), i));
        }
        assertFalse(MockPermit2(router.PERMIT2()).used(address(router), builder.queues()));
        // Even Permit2 cannot reuse the authorization after the owner-initiated queue returns.
        vm.prank(router.PERMIT2());
        assertEq(router.isValidSignature(keccak256("inactive permit"), ""), bytes4(0xffffffff));
    }

    function afterInvariant() public {
        builder.closeAll();
        invariantBuilderAssetsStayWithRouterHelperOrTeam();
        invariantBuilderOperationsCannotConsumeBettorEth();
        assertEq(address(router).balance, 0);
        assertEq(address(vault).balance, 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(helper.claimable(team), 0);
        assertEq(rewards.tokenBuyAllowance(address(router)), 0);
        assertEq(token.balanceOf(team), builder.mintedTokens());
    }
}
