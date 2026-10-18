// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {KeelBase} from "./KeelBase.t.sol";
import {KeelSpinVault} from "../src/KeelSpinVault.sol";
import {MockFWA, MockNFT, MockFloor} from "./mocks/Protocols.sol";

contract RoundHandler is Test {
    KeelSpinVault public vault;
    MockFWA public pool;
    MockNFT public nft;
    MockFloor public floor;
    address public team;
    uint256 public minted;
    address[12] public actors;

    constructor(KeelSpinVault vault_, MockFWA pool_, MockNFT nft_, MockFloor floor_, address team_) {
        vault = vault_;
        pool = pool_;
        nft = nft_;
        floor = floor_;
        team = team_;
        for (uint256 i; i < 12; ++i) {
            actors[i] = address(uint160(0x50000 + i));
        }
    }

    function bet(uint256 actorSeed, uint96 amountSeed, bool oldRound, uint256 roundSeed) external {
        address actor = actors[actorSeed % 12];
        uint256 amount = bound(uint256(amountSeed), 0.001 ether, 0.3 ether);
        uint256 id = 1 + roundSeed % vault.roundCount();
        vm.deal(actor, actor.balance + amount);
        vm.prank(actor);
        if (oldRound) vault.betInto{value: amount}(id);
        else vault.bet{value: amount}();
    }

    function withdraw(uint256 actorSeed, uint256 roundSeed) external {
        uint256 id = 1 + roundSeed % vault.roundCount();
        vm.prank(actors[actorSeed % 12]);
        vault.withdraw(id);
    }

    function claim(uint256 actorSeed, uint256 roundSeed) external {
        uint256 count = vault.roundCount();
        for (uint256 n; n < count; ++n) {
            uint256 id = 1 + (roundSeed % count + n) % count;
            if (vault.rounds(id).state != KeelSpinVault.State.Settled) continue;
            for (uint256 j; j < 12; ++j) {
                address actor = actors[(actorSeed % 12 + j) % 12];
                if (vault.stake(id, actor) == 0) continue;
                vm.prank(actor);
                vault.claim(id);
                return;
            }
        }
    }

    function spin(uint256 roundSeed) external {
        vault.spin(1 + roundSeed % vault.roundCount());
    }

    function movePrice(uint96 feeSeed, uint96 vrfSeed) external {
        pool.setPrice(bound(uint256(feeSeed), 0.03 ether, 0.15 ether), bound(uint256(vrfSeed), 0, 0.01 ether));
    }

    function fulfill(bool refunded, bool expired) external {
        uint256 id = vault.activeRoundId();
        if (id == 0) return;
        KeelSpinVault.Round memory r = vault.rounds(id);
        if (r.state != KeelSpinVault.State.Spinning) return;
        if (refunded) pool.refund(r.requestId, expired);
        else pool.allocate(r.requestId, nft, ++minted, 1 ether, address(this));
        vault.syncRound(id);
    }

    function decide(bool keep) external {
        uint256 id = vault.activeRoundId();
        if (id == 0) return;
        if (vault.rounds(id).state != KeelSpinVault.State.Allocated) return;
        floor.set(keep ? 30 ether : 0.5 ether, block.timestamp);
        // Short window triggers fallback immediately and avoids waiting in stateful runs.
        pool.setWindow(20 minutes);
        vault.requestDecision(id);
    }

    function sell(uint256 roundSeed, uint96 amountSeed) external {
        uint256 id = 1 + roundSeed % vault.roundCount();
        uint256 amount = bound(uint256(amountSeed), 1, 3 ether);
        vm.deal(team, team.balance + amount);
        vm.prank(team);
        vault.depositSaleProceeds{value: amount}(id, keccak256(abi.encode(id, amount)));
    }

    function claimFee() external {
        vm.prank(team);
        vault.claimFees(payable(team));
    }
    receive() external payable {}
}

contract KeelInvariantTest is KeelBase {
    RoundHandler internal handler;

    function setUp() public override {
        super.setUp();
        vault.setFeeBps(200);
        handler = new RoundHandler(vault, pool, nft, floor, team);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.bet.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.spin.selector;
        selectors[4] = handler.movePrice.selector;
        selectors[5] = handler.fulfill.selector;
        selectors[6] = handler.decide.selector;
        selectors[7] = handler.sell.selector;
        selectors[8] = handler.claimFee.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantClaimablePlusOpenBalancesNeverExceedEth() public view {
        uint256 liability;
        uint256 allCash;
        uint256 shares;
        uint256 unresolved;
        for (uint256 id = 1; id <= vault.roundCount(); ++id) {
            KeelSpinVault.Round memory r = vault.rounds(id);
            allCash += r.cash;
            shares += r.totalShares;
            if (r.state != KeelSpinVault.State.AwaitingSale && r.state != KeelSpinVault.State.Settled) {
                unresolved += r.totalShares;
            }
            if (r.state == KeelSpinVault.State.Open) liability += r.cash;
            uint256 actorShares;
            for (uint256 j; j < 12; ++j) {
                liability += vault.claimable(id, handler.actors(j));
                actorShares += vault.stake(id, handler.actors(j));
            }
            assertEq(actorShares, r.totalShares);
        }
        assertLe(liability, address(vault).balance);
        assertEq(allCash + vault.feeCredit(team), vault.accountedETH());
        assertEq(shares, vault.totalSharesOutstanding());
        assertEq(unresolved, vault.unresolvedShares());
        assertLe(vault.accountedETH(), address(vault).balance);
    }

    function invariantAtMostOneUnresolvedSpin() public view {
        uint256 active;
        for (uint256 id = 1; id <= vault.roundCount(); ++id) {
            KeelSpinVault.State state = vault.rounds(id).state;
            if (
                state == KeelSpinVault.State.Spinning || state == KeelSpinVault.State.Allocated
                    || state == KeelSpinVault.State.OraclePending || state == KeelSpinVault.State.DecisionReady
            ) {
                assertEq(id, vault.activeRoundId());
                ++active;
            }
            assertLe(vault.rounds(id).bettors, 500);
        }
        assertLe(active, 1);
        assertEq(active == 0, vault.activeRoundId() == 0);
    }
}
