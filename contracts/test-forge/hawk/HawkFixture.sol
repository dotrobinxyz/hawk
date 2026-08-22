//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import {Test} from "forge-std/Test.sol";

import {HawkRegistry} from "../../contracts/hawk/HawkRegistry.sol";
import {HawkBaseRegistrar} from "../../contracts/hawk/HawkBaseRegistrar.sol";
import {HawkRegistrarController} from "../../contracts/hawk/HawkRegistrarController.sol";
import {HawkPriceOracle, AggregatorV3Interface} from "../../contracts/hawk/HawkPriceOracle.sol";
import {HawkReservedList} from "../../contracts/hawk/HawkReservedList.sol";
import {HawkWrapper} from "../../contracts/hawk/HawkWrapper.sol";
import {HawkMetadata} from "../../contracts/hawk/HawkMetadata.sol";
import {IHawkPriceOracle} from "../../contracts/hawk/IHawkPriceOracle.sol";
import {IETHRegistrarController, IPriceOracle} from "../../contracts/ethregistrar/IETHRegistrarController.sol";
import {ReverseRegistrar} from "../../contracts/reverseRegistrar/ReverseRegistrar.sol";
import {DefaultReverseRegistrar} from "../../contracts/reverseRegistrar/DefaultReverseRegistrar.sol";
import {PublicResolver} from "../../contracts/resolvers/PublicResolver.sol";
import {INameWrapper} from "../../contracts/wrapper/INameWrapper.sol";
import {IMetadataService} from "../../contracts/wrapper/IMetadataService.sol";
import {IBaseRegistrar} from "../../contracts/ethregistrar/IBaseRegistrar.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IReverseRegistrar} from "../../contracts/reverseRegistrar/IReverseRegistrar.sol";
import {IDefaultReverseRegistrar} from "../../contracts/reverseRegistrar/IDefaultReverseRegistrar.sol";
import {ENS} from "../../contracts/registry/ENS.sol";

import {MockAggregator} from "../../contracts/hawk/mocks/MockAggregator.sol";
import {MockUSDC} from "../../contracts/hawk/mocks/MockUSDC.sol";

/// @dev Deploys the full Hawk stack with mainnet-shaped parameters against
///      mocks for the external dependencies (Chainlink feed, USDC).
abstract contract HawkFixture is Test {
    // namehash('hawk') / keccak256('hawk')
    bytes32 constant HAWK_NODE =
        0xf431efc1fb1b854a38191ac67de7e1ee70205b40f71cb927c938685e82e05403;
    bytes32 constant HAWK_LABELHASH =
        0x20a425b46037bc1d600066c89af6258ff77bbf40ae831044e2d8f4a1605fc5f6;
    bytes32 constant ADDR_REVERSE_NODE =
        0x91d1777781884d03a6757a803996e38de2a42967fb37eeaca72729271025a9e2;

    // attoUSD per second: $100 / $25 / $5 per 365-day year
    uint256 constant RATE3 = 3170979198376;
    uint256 constant RATE4 = 792744799594;
    uint256 constant RATE5 = 158548959918;

    uint256 constant GRACE = 90 days;
    uint256 constant PREMIUM_START = 1000e18; // $1,000 in attoUSD
    uint256 constant PREMIUM_DAYS = 21;
    uint256 constant MIN_COMMIT_AGE = 60;
    uint256 constant MAX_COMMIT_AGE = 86400;
    uint256 constant MAX_FEED_AGE = 36 hours;
    int256 constant ETH_PRICE = 2000e8; // $2,000, 8 decimals

    uint256 constant START_TIME = 1_700_000_000;

    HawkRegistry registry;
    HawkBaseRegistrar registrar;
    HawkRegistrarController controller;
    HawkPriceOracle oracle;
    HawkReservedList reserved;
    HawkWrapper wrapper;
    HawkMetadata metadata;
    ReverseRegistrar reverseRegistrar;
    DefaultReverseRegistrar defaultReverseRegistrar;
    PublicResolver resolver;
    MockAggregator feed;
    MockUSDC usdc;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public virtual {
        vm.warp(START_TIME);

        registry = new HawkRegistry();
        registrar = new HawkBaseRegistrar(registry, HAWK_NODE, GRACE);
        registry.setSubnodeOwner(bytes32(0), HAWK_LABELHASH, address(registrar));

        // reverse tree: reverse → us, addr.reverse → ReverseRegistrar
        reverseRegistrar = new ReverseRegistrar(registry);
        registry.setSubnodeOwner(bytes32(0), keccak256("reverse"), address(this));
        registry.setSubnodeOwner(
            _namehash(bytes32(0), keccak256("reverse")),
            keccak256("addr"),
            address(reverseRegistrar)
        );
        defaultReverseRegistrar = new DefaultReverseRegistrar();

        reserved = new HawkReservedList();
        feed = new MockAggregator(8, ETH_PRICE);
        oracle = _deployOracle(0); // no promo by default
        usdc = new MockUSDC();

        wrapper = new HawkWrapper(
            registry,
            IBaseRegistrar(address(registrar)),
            IMetadataService(address(0))
        );
        registrar.addController(address(wrapper));

        metadata = new HawkMetadata(registrar, wrapper);
        wrapper.setMetadataService(IMetadataService(address(metadata)));
        registrar.setMetadataProvider(metadata);

        controller = new HawkRegistrarController(
            registrar,
            IHawkPriceOracle(address(oracle)),
            28 days,
            MIN_COMMIT_AGE,
            MAX_COMMIT_AGE,
            IReverseRegistrar(address(reverseRegistrar)),
            IDefaultReverseRegistrar(address(defaultReverseRegistrar)),
            registry,
            IERC20Metadata(address(usdc)),
            reserved,
            INameWrapper(address(wrapper))
        );
        registrar.addController(address(controller));
        reverseRegistrar.setController(address(controller), true);
        defaultReverseRegistrar.setController(address(controller), true);
        wrapper.setController(address(controller), true);

        resolver = new PublicResolver(
            registry,
            INameWrapper(address(wrapper)),
            address(controller),
            address(reverseRegistrar)
        );
        reverseRegistrar.setDefaultResolver(address(resolver));

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
    }

    function _deployOracle(
        uint256 promoEnd
    ) internal returns (HawkPriceOracle) {
        uint256[] memory rates = new uint256[](5);
        rates[0] = RATE3; // 1-char: unregisterable; priced as 3-char defensively
        rates[1] = RATE3; // 2-char: unregisterable; priced as 3-char defensively
        rates[2] = RATE3;
        rates[3] = RATE4;
        rates[4] = RATE5;
        return
            new HawkPriceOracle(
                AggregatorV3Interface(address(feed)),
                MAX_FEED_AGE,
                rates,
                PREMIUM_START,
                PREMIUM_DAYS,
                GRACE,
                promoEnd
            );
    }

    function _namehash(
        bytes32 parent,
        bytes32 labelhash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(parent, labelhash));
    }

    function _hawkNode(string memory label) internal pure returns (bytes32) {
        return _namehash(HAWK_NODE, keccak256(bytes(label)));
    }

    function _makeRegistration(
        string memory label,
        address owner,
        uint256 duration,
        bytes32 secret,
        address resolver_,
        uint8 reverseRecord
    )
        internal
        pure
        returns (IETHRegistrarController.Registration memory registration)
    {
        registration = IETHRegistrarController.Registration({
            label: label,
            owner: owner,
            duration: duration,
            secret: secret,
            resolver: resolver_,
            data: new bytes[](0),
            reverseRecord: reverseRecord,
            referrer: bytes32(0)
        });
    }

    /// @dev Full commit-reveal registration paying in ETH, as `who`.
    function _registerETH(
        address who,
        string memory label,
        uint256 duration
    ) internal returns (uint256 paid) {
        IETHRegistrarController.Registration memory registration = _makeRegistration(
            label,
            who,
            duration,
            keccak256("secret"),
            address(0),
            0
        );
        vm.prank(who);
        controller.commit(controller.makeCommitment(registration));
        vm.warp(block.timestamp + MIN_COMMIT_AGE);
        IPriceOracle.Price memory price = controller.rentPrice(label, duration);
        paid = price.base + price.premium;
        vm.prank(who);
        controller.register{value: paid}(registration);
    }

    /// @dev Full commit-reveal registration paying in USDC, as `who`.
    function _registerUSDC(
        address who,
        string memory label,
        uint256 duration
    ) internal returns (uint256 paid) {
        IETHRegistrarController.Registration memory registration = _makeRegistration(
            label,
            who,
            duration,
            keccak256("secret"),
            address(0),
            0
        );
        vm.prank(who);
        controller.commit(controller.makeCommitment(registration));
        vm.warp(block.timestamp + MIN_COMMIT_AGE);
        IPriceOracle.Price memory price = controller.rentPriceUSDC(
            label,
            duration
        );
        paid = price.base + price.premium;
        vm.startPrank(who);
        usdc.approve(address(controller), paid);
        controller.registerWithUSDC(registration, paid);
        vm.stopPrank();
    }
}
