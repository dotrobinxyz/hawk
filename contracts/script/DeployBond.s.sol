// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Script, console2} from "forge-std/Script.sol";
import {HawkBond, IRegistrarBond, IWrapperBond, IERC20Bond, IAggregatorBond, IStateViewBond, IUniversalRouterBond} from "../contracts/hawk/HawkBond.sol";

/// @notice Deploys HawkBond on Base mainnet, wires the verified buyback
///         route (USDC → ETH → HAWK on Uniswap v4), and hands ownership to
///         the treasury Safe — all in one broadcast. After this the owner's
///         only remaining power (re-routing) sits with the Safe.
contract DeployBond is Script {
    address constant SAFE = 0xd0eC82124401A30d8337FEF77899e883bb12Df0b;
    address constant REGISTRAR = 0x83dcABD50E531325C76b9CB07F4C04Aca187722E;
    address constant WRAPPER = 0x0B922e8B56c778667AbDbBBa522880F98362c6C8;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant HAWK = 0xb20000000000000000000024008843f777304E01;
    address constant FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // ETH/USD
    address constant STATE_VIEW = 0xA3c0c9b65baD0b08107Aa264b0f3dB444b867A71;
    address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant HAWK_HOOKS = 0x985C14BAa2a18316ffdA0aeFB3a632fAdfcA2AcC;
    uint256 constant MAX_FEED_AGE = 129600; // 36h
    // namehash('hawk')
    bytes32 constant HAWK_NODE =
        0xf431efc1fb1b854a38191ac67de7e1ee70205b40f71cb927c938685e82e05403;
    // keccak-verified live HAWK/ETH pool
    bytes32 constant HAWK_POOL_ID =
        0x9ee0da73813036321919b0ba089d02dd4d3f19ea7d4fbcba80beb29d5051c685;

    function run() external {
        vm.startBroadcast();

        HawkBond bond = new HawkBond(
            HawkBond.Config({
                owner: msg.sender,
                registrar: IRegistrarBond(REGISTRAR),
                wrapper: IWrapperBond(WRAPPER),
                baseNode: HAWK_NODE,
                usdc: IERC20Bond(USDC),
                hawk: IERC20Bond(HAWK),
                feed: IAggregatorBond(FEED),
                maxFeedAge: MAX_FEED_AGE,
                stateView: IStateViewBond(STATE_VIEW),
                hawkPoolId: HAWK_POOL_ID,
                treasury: SAFE,
                router: IUniversalRouterBond(UNIVERSAL_ROUTER)
            })
        );

        HawkBond.PoolKey memory usdcEth = HawkBond.PoolKey(address(0), USDC, 500, 10, address(0));
        HawkBond.PoolKey memory ethHawk =
            HawkBond.PoolKey(address(0), HAWK, 0, 200, HAWK_HOOKS);
        require(keccak256(abi.encode(ethHawk)) == HAWK_POOL_ID, "pool id mismatch");
        bond.setRoute(usdcEth, ethHawk);
        bond.setOwner(SAFE);

        vm.stopBroadcast();
        console2.log("HawkBond:", address(bond));
    }
}
