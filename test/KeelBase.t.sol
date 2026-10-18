// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeelSpinVault} from "../src/KeelSpinVault.sol";
import {KeelFwaRouter} from "../src/KeelFwaRouter.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockFWA, MockNFT, MockIMD, MockFloor, MockIntake, RejectNFT} from "./mocks/Protocols.sol";

abstract contract KeelBase is Test {
    KeelSpinVault internal vault;
    KeelFwaRouter internal router;
    MockFWA internal pool;
    MockNFT internal nft;
    MockIMD internal imd;
    MockFloor internal floor;
    MockIntake internal intake;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal team = address(0x7EA7);
    address internal depositor = address(0xD3F0);
    address internal keeper = address(0xB07);
    uint256 internal constant SIGNER_KEY = 0xA77E57;
    uint256 internal tokenCounter;

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(1800057600 + 1 hours);
        vm.txGasPrice(10 gwei);
        pool = new MockFWA();
        nft = new MockNFT();
        imd = new MockIMD();
        floor = new MockFloor();
        intake = new MockIntake();
        vault = new KeelSpinVault(
            address(this), address(pool), address(floor), address(intake), address(imd), vm.addr(SIGNER_KEY), team
        );
        router = new KeelFwaRouter(address(this), address(vault), address(pool));
        vault.setRouter(address(router));
        vm.deal(address(this), 10000 ether);
        vm.deal(address(pool), 10000 ether);
        vm.deal(alice, 10000 ether);
        vm.deal(bob, 10000 ether);
        vm.deal(keeper, 1 ether);
        imd.mint(address(vault), 100 ether);
    }

    function _bet(address bettor, uint256 amount) internal {
        vm.prank(bettor);
        vault.bet{value: amount}();
    }

    function _fund() internal returns (uint256 id) {
        id = vault.currentRoundId();
        _bet(alice, vault.liveTarget());
    }

    function _spin(uint256 id) internal {
        vm.prank(keeper);
        vault.spin(id);
    }

    function _allocate(uint256 id) internal returns (uint256 listingId) {
        listingId = pool.allocate(vault.rounds(id).requestId, nft, ++tokenCounter, 1 ether, depositor);
        vault.syncRound(id);
    }

    function _ready() internal returns (uint256 id) {
        id = _fund();
        _spin(id);
        _allocate(id);
    }

    function _ask() internal returns (uint256 id, bytes32 requestId) {
        id = _ready();
        vault.requestDecision(id);
        requestId = vault.rounds(id).oracleRequestId;
    }

    function _attestation(uint256 answer) internal view returns (OracleAttestation.Attestation memory a) {
        a.requestId = keccak256(abi.encode("oracle UUID", intake.nonce()));
        a.chainId = 1;
        a.questionHash = keccak256("question with resolved window");
        a.answerType = 3;
        a.answer = abi.encode(answer);
        a.figure = answer;
        a.fromBlock = 100;
        a.toBlock = 200;
        a.blockHash = bytes32(uint256(7));
        a.panelJobId = keccak256("panel");
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 hours);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, vault.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _answer(uint256 id, uint256 offer) internal {
        OracleAttestation.Attestation memory a = _attestation(offer);
        assertTrue(intake.result(vault.rounds(id).oracleRequestId, a, _sign(a)), "callback failed under 200k gas");
    }

    function _fallback(uint256 id) internal {
        vm.warp(vault.fallbackAt(id));
        vault.settleFallback(id);
    }

    function _state(uint256 id, KeelSpinVault.State state) internal view {
        assertEq(uint256(vault.rounds(id).state), uint256(state));
    }

    function _solvent() internal view {
        assertLe(vault.accountedETH(), address(vault).balance);
    }
    receive() external payable {}
}
