//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import {HawkFixture} from "./HawkFixture.sol";
import {HawkRegistrarController} from "../../contracts/hawk/HawkRegistrarController.sol";
import {IETHRegistrarController} from "../../contracts/ethregistrar/IETHRegistrarController.sol";

/// @dev A contract registrant that, on receiving its ETH refund, tries to
///      reenter the controller and register a *second* name for which it holds
///      a matured commitment and funds. With `nonReentrant` (security-review
///      INFO-2) the reentry reverts; without it, the second name would be
///      registered. Proves the guard is wired to the register entrypoint.
contract ReentrantRegistrant {
    HawkRegistrarController public immutable controller;
    IETHRegistrarController.Registration private regB;
    bool public reentered;
    bool public reentryReverted;

    constructor(HawkRegistrarController _controller) {
        controller = _controller;
    }

    function stash(
        IETHRegistrarController.Registration calldata _regB
    ) external {
        regB = _regB;
    }

    function commit(bytes32 commitment) external {
        controller.commit(commitment);
    }

    function attack(
        IETHRegistrarController.Registration calldata regA,
        uint256 value
    ) external {
        controller.register{value: value}(regA);
    }

    receive() external payable {
        if (!reentered) {
            reentered = true;
            try controller.register{value: 1 ether}(regB) {
                // reached only if the guard is absent
            } catch {
                reentryReverted = true;
            }
        }
    }
}

contract HawkReentrancyTest is HawkFixture {
    uint256 constant YEAR = 365 days;

    function test_nonReentrant_blocksRefundReentry() public {
        ReentrantRegistrant attacker = new ReentrantRegistrant(controller);
        vm.deal(address(attacker), 100 ether);

        IETHRegistrarController.Registration memory regA = _makeRegistration(
            "attackera",
            address(attacker),
            YEAR,
            keccak256("a"),
            address(0),
            0
        );
        IETHRegistrarController.Registration memory regB = _makeRegistration(
            "attackerb",
            address(attacker),
            YEAR,
            keccak256("b"),
            address(0),
            0
        );
        attacker.stash(regB);

        // Both commitments placed and matured.
        attacker.commit(controller.makeCommitment(regA));
        attacker.commit(controller.makeCommitment(regB));
        vm.warp(block.timestamp + MIN_COMMIT_AGE);

        // Overpay so the controller issues an ETH refund, invoking receive()
        // and the reentry attempt.
        uint256 priceA = controller.rentPrice("attackera", YEAR).base;
        attacker.attack(regA, priceA + 1 ether);

        // The outer registration completed normally.
        assertEq(
            registrar.ownerOf(uint256(keccak256("attackera"))),
            address(attacker)
        );
        // The reentry fired and was blocked by nonReentrant.
        assertTrue(attacker.reentered(), "receive did not fire");
        assertTrue(attacker.reentryReverted(), "reentry was NOT blocked");
        // The second name was never registered — the decisive assertion:
        // without the guard the reentry would have registered it.
        assertTrue(
            controller.available("attackerb"),
            "reentry registered a second name"
        );
    }
}
