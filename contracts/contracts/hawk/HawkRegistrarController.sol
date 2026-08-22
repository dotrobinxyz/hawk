//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {HawkBaseRegistrar} from "./HawkBaseRegistrar.sol";
import {StringUtils} from "../utils/StringUtils.sol";
import {Resolver} from "../resolvers/Resolver.sol";
import {ENS} from "../registry/ENS.sol";
import {IReverseRegistrar} from "../reverseRegistrar/IReverseRegistrar.sol";
import {IDefaultReverseRegistrar} from "../reverseRegistrar/IDefaultReverseRegistrar.sol";
import {IETHRegistrarController, IPriceOracle} from "../ethregistrar/IETHRegistrarController.sol";
import {IHawkRegistrarController} from "./IHawkRegistrarController.sol";
import {IHawkPriceOracle} from "./IHawkPriceOracle.sol";
import {IReservedList} from "./IReservedList.sol";
import {ERC20Recoverable} from "../utils/ERC20Recoverable.sol";
import {INameWrapper} from "../wrapper/INameWrapper.sol";

/// @title HawkRegistrarController
/// @notice Public commit-reveal registration and renewal for .hawk names,
///         payable in ETH (Chainlink-converted) or in USDC at flat USD prices.
///
/// @dev Copy of upstream ETHRegistrarController (ens-contracts v1.7.0) with
///      the following deliberate diffs — everything else is verbatim:
///      1. TLD: HAWK_NODE (namehash('hawk')) replaces ETH_NODE, and reverse
///         records are set as "<label>.hawk".
///      2. Dual payment: `registerWithUSDC`/`renewWithUSDC` charge the flat
///         USD price in USDC (rounded up to token units), pulled via
///         transferFrom with a caller-supplied cap. The upstream ETH paths
///         are unchanged in behaviour. The shared registration/renewal body
///         is factored into `_register`/`_renew` so both payment paths run
///         identical logic. USDC paths additionally emit `USDCPayment`.
///      3. Reserved names: `_available` also requires the label not to be on
///         the owner-updatable HawkReservedList. Renewals are unaffected.
///      4. Duration bounds: MIN_REGISTRATION_DURATION is immutable
///         (mainnet: the upstream 28 days; testnet: shortened for lifecycle
///         rehearsal) and MAX_REGISTRATION_DURATION (3650 days) caps a single
///         registration or renewal transaction. Checks run in `_register`
///         instead of the pure `makeCommitment`.
///      5. Registrations go through `base.registerWithLabel`, recording the
///         plaintext label for fully on-chain metadata.
///      6. ETH refunds and `withdraw` use OpenZeppelin's
///         `Address.sendValue` instead of `transfer`, so smart-contract
///         wallets (the norm on an account-abstraction chain) are not bricked
///         by the 2300 gas stipend. Both run after all state changes. Because
///         `sendValue` forwards all gas (unlike `transfer`'s 2300-gas stipend),
///         the four register/renew entrypoints carry `nonReentrant` as
///         defense-in-depth (security-review INFO-2); `withdraw` is an
///         owner-only sink and intentionally unguarded.
///      7. Renewals go through `wrapper.renew` (as ENS's wrapped-era
///         controller did) instead of the registrar directly, so a wrapped
///         name's fuse expiry stays in sync after renewal. Upstream's direct
///         renewal leaves wrapped expiries stale (their test for it is
///         skipped upstream). For unwrapped names the wrapper passes the
///         renewal straight through to the registrar.
///      Treasury: ETH exits via `withdraw` (to owner); USDC exits via the
///      inherited `recoverFunds` (owner-only). Operational invariant: this
///      controller must remain a controller on both the registrar and the
///      wrapper, and the wrapper a controller on the registrar.
contract HawkRegistrarController is
    Ownable,
    IHawkRegistrarController,
    ERC165,
    ERC20Recoverable,
    ReentrancyGuard
{
    using StringUtils for *;
    using SafeERC20 for IERC20;

    /// @notice The bitmask for the Ethereum reverse record.
    uint8 constant REVERSE_RECORD_ETHEREUM_BIT = 1;

    /// @notice The bitmask for the default reverse record.
    uint8 constant REVERSE_RECORD_DEFAULT_BIT = 2;

    /// @notice The minimum duration for a registration.
    ///         Hawk diff (4): immutable (upstream: constant 28 days) so the
    ///         full lifecycle can be rehearsed on testnet with short timers.
    ///         Mainnet deploys with exactly 28 days. Because immutables are
    ///         unreadable from `pure` functions, the duration checks live in
    ///         `_register` rather than `makeCommitment`; a commitment with a
    ///         bad duration is accepted but its registration reverts.
    uint256 public immutable MIN_REGISTRATION_DURATION;

    /// @notice Hawk diff (4): the maximum duration for a single registration
    ///         or renewal transaction (10 years).
    uint256 public constant MAX_REGISTRATION_DURATION = 3650 days;

    // @notice The node (i.e. namehash) for the hawk TLD.
    bytes32 private constant HAWK_NODE =
        0xf431efc1fb1b854a38191ac67de7e1ee70205b40f71cb927c938685e82e05403;

    /// @notice The maximum expiry time for a registration.
    uint64 private constant MAX_EXPIRY = type(uint64).max;

    /// @notice The ENS registry.
    ENS public immutable ens;

    // @notice The base registrar implementation for the hawk TLD.
    HawkBaseRegistrar immutable base;

    /// @notice The minimum time a commitment must exist to be valid.
    uint256 public immutable minCommitmentAge;

    /// @notice The maximum time a commitment can exist to be valid.
    uint256 public immutable maxCommitmentAge;

    /// @notice The registrar for addr.reverse. (i.e. reverse for coinType 60)
    IReverseRegistrar public immutable reverseRegistrar;

    /// @notice The registrar for default.reverse. (i.e. fallback reverse for all EVM chains)
    IDefaultReverseRegistrar public immutable defaultReverseRegistrar;

    /// @notice The price oracle for the hawk TLD.
    IHawkPriceOracle public immutable prices;

    /// @notice Hawk diff (2): the USDC token accepted for flat-USD payment.
    IERC20 public immutable usdc;

    /// @notice Hawk diff (2): 10^(18 - usdc.decimals()); converts attoUSD to
    ///         USDC base units.
    uint256 private immutable usdcUnitScale;

    /// @notice Hawk diff (3): labels on this list cannot be newly registered.
    IReservedList public immutable reservedList;

    /// @notice Hawk diff (7): renewals are routed through the wrapper to
    ///         keep wrapped-name expiries in sync.
    INameWrapper public immutable wrapper;

    /// @notice A mapping of commitments to their timestamp.
    mapping(bytes32 => uint256) public commitments;

    /// @notice Thrown when a commitment is not found.
    error CommitmentNotFound(bytes32 commitment);

    /// @notice Thrown when a commitment is too new.
    error CommitmentTooNew(
        bytes32 commitment,
        uint256 minimumCommitmentTimestamp,
        uint256 currentTimestamp
    );

    /// @notice Thrown when a commitment is too old.
    error CommitmentTooOld(
        bytes32 commitment,
        uint256 maximumCommitmentTimestamp,
        uint256 currentTimestamp
    );

    /// @notice Thrown when a name is not available to register.
    error NameNotAvailable(string name);

    /// @notice Thrown when the duration supplied for a registration is too short.
    error DurationTooShort(uint256 duration);

    /// @notice Thrown when the duration supplied exceeds MAX_REGISTRATION_DURATION.
    error DurationTooLong(uint256 duration);

    /// @notice Thrown when data is supplied for a registration without a resolver.
    error ResolverRequiredWhenDataSupplied();

    /// @notice Thrown when a reverse record is requested without a resolver.
    error ResolverRequiredForReverseRecord();

    /// @notice Thrown when a matching unexpired commitment exists.
    error UnexpiredCommitmentExists(bytes32 commitment);

    /// @notice Thrown when the value sent for a registration is insufficient.
    error InsufficientValue();

    /// @notice Thrown when the USDC price exceeds the caller-supplied cap.
    error MaxPriceExceeded(uint256 required, uint256 maxAllowed);

    /// @notice Thrown when the payment token reports more than 18 decimals.
    error UnsupportedTokenDecimals();

    /// @notice Thrown when the maximum commitment age is too low.
    error MaxCommitmentAgeTooLow();

    /// @notice Thrown when the maximum commitment age is too high.
    error MaxCommitmentAgeTooHigh();

    /// @notice Emitted when a name is registered.
    ///
    /// @param label The label of the name.
    /// @param labelhash The keccak256 hash of the label.
    /// @param owner The owner of the name.
    /// @param baseCost The base cost of the name, in the payment asset used.
    /// @param premium The premium cost of the name, in the payment asset used.
    /// @param expires The expiry time of the name.
    /// @param referrer The referrer of the registration.
    event NameRegistered(
        string label,
        bytes32 indexed labelhash,
        address indexed owner,
        uint256 baseCost,
        uint256 premium,
        uint256 expires,
        bytes32 referrer
    );

    /// @notice Emitted when a name is renewed.
    ///
    /// @param label The label of the name.
    /// @param labelhash The keccak256 hash of the label.
    /// @param cost The cost of the name, in the payment asset used.
    /// @param expires The expiry time of the name.
    /// @param referrer The referrer of the registration.
    event NameRenewed(
        string label,
        bytes32 indexed labelhash,
        uint256 cost,
        uint256 expires,
        bytes32 referrer
    );

    /// @notice Hawk diff (2): emitted alongside NameRegistered/NameRenewed
    ///         when payment was taken in USDC. Amounts in USDC base units.
    event USDCPayment(
        bytes32 indexed labelhash,
        address indexed payer,
        uint256 amount
    );

    /// @notice Constructor for the HawkRegistrarController.
    ///
    /// @param _base The base registrar implementation for the hawk TLD.
    /// @param _prices The price oracle for the hawk TLD.
    /// @param _minCommitmentAge The minimum time a commitment must exist to be valid.
    /// @param _maxCommitmentAge The maximum time a commitment can exist to be valid.
    /// @param _reverseRegistrar The registrar for addr.reverse.
    /// @param _defaultReverseRegistrar The registrar for default.reverse.
    /// @param _ens The ENS registry.
    /// @param _usdc The USDC token accepted for flat-USD payment.
    /// @param _reservedList The reserved-name list enforced on registration.
    constructor(
        HawkBaseRegistrar _base,
        IHawkPriceOracle _prices,
        uint256 _minRegistrationDuration,
        uint256 _minCommitmentAge,
        uint256 _maxCommitmentAge,
        IReverseRegistrar _reverseRegistrar,
        IDefaultReverseRegistrar _defaultReverseRegistrar,
        ENS _ens,
        IERC20Metadata _usdc,
        IReservedList _reservedList,
        INameWrapper _wrapper
    ) {
        if (_maxCommitmentAge <= _minCommitmentAge)
            revert MaxCommitmentAgeTooLow();

        if (_maxCommitmentAge > block.timestamp)
            revert MaxCommitmentAgeTooHigh();

        uint8 tokenDecimals = _usdc.decimals();
        if (tokenDecimals > 18) revert UnsupportedTokenDecimals();

        ens = _ens;
        base = _base;
        prices = _prices;
        MIN_REGISTRATION_DURATION = _minRegistrationDuration;
        minCommitmentAge = _minCommitmentAge;
        maxCommitmentAge = _maxCommitmentAge;
        reverseRegistrar = _reverseRegistrar;
        defaultReverseRegistrar = _defaultReverseRegistrar;
        usdc = _usdc;
        usdcUnitScale = 10 ** (18 - tokenDecimals);
        reservedList = _reservedList;
        wrapper = _wrapper;
    }

    /// @notice Returns the price of a registration for the given label and duration.
    ///
    /// @param label The label of the name.
    /// @param duration The duration of the registration.
    /// @return price The price of the registration, in wei.
    function rentPrice(
        string calldata label,
        uint256 duration
    ) public view override returns (IPriceOracle.Price memory price) {
        bytes32 labelhash = keccak256(bytes(label));
        price = _rentPrice(label, labelhash, duration);
    }

    /// @notice Hawk diff (2): returns the price of a registration in USDC
    ///         base units (flat USD price rounded up to token units).
    ///
    /// @param label The label of the name.
    /// @param duration The duration of the registration.
    /// @return price The price of the registration, in USDC base units.
    function rentPriceUSDC(
        string calldata label,
        uint256 duration
    ) public view override returns (IPriceOracle.Price memory price) {
        bytes32 labelhash = keccak256(bytes(label));
        price = _rentPriceUSDC(label, labelhash, duration);
    }

    /// @notice Returns true if the label is valid for registration.
    ///
    /// @param label The label to check.
    /// @return True if the label is valid, false otherwise.
    function valid(string calldata label) public pure returns (bool) {
        return label.strlen() >= 3;
    }

    /// @notice Returns true if the label is valid and available for registration.
    ///
    /// @param label The label to check.
    /// @return True if the label is valid and available, false otherwise.
    function available(
        string calldata label
    ) public view override returns (bool) {
        bytes32 labelhash = keccak256(bytes(label));
        return _available(label, labelhash);
    }

    /// @notice Returns the commitment for a registration.
    ///
    /// @param registration The registration to make a commitment for.
    /// @return commitment The commitment for the registration.
    function makeCommitment(
        Registration calldata registration
    ) public pure override returns (bytes32 commitment) {
        if (registration.data.length > 0 && registration.resolver == address(0))
            revert ResolverRequiredWhenDataSupplied();

        if (
            registration.reverseRecord != 0 &&
            registration.resolver == address(0)
        ) revert ResolverRequiredForReverseRecord();

        // Hawk diff (4): duration bounds are checked in _register — an
        // immutable minimum cannot be read from this pure function.

        return keccak256(abi.encode(registration));
    }

    /// @notice Commits a registration.
    ///
    /// @param commitment The commitment to commit.
    function commit(bytes32 commitment) public override {
        if (commitments[commitment] + maxCommitmentAge >= block.timestamp) {
            revert UnexpiredCommitmentExists(commitment);
        }
        commitments[commitment] = block.timestamp;
    }

    /// @notice Registers a name, paying in ETH.
    ///
    /// @param registration The registration to register.
    /// @param registration.label The label of the name.
    /// @param registration.owner The owner of the name.
    /// @param registration.duration The duration of the registration.
    /// @param registration.resolver The resolver for the name.
    /// @param registration.data The data for the name.
    /// @param registration.reverseRecord Which reverse record(s) to set.
    /// @param registration.referrer The referrer of the registration.
    function register(
        Registration calldata registration
    ) public payable override nonReentrant {
        bytes32 labelhash = keccak256(bytes(registration.label));
        IPriceOracle.Price memory price = _rentPrice(
            registration.label,
            labelhash,
            registration.duration
        );
        uint256 totalPrice = price.base + price.premium;
        if (msg.value < totalPrice) revert InsufficientValue();

        _register(registration, labelhash, price);

        if (msg.value > totalPrice)
            Address.sendValue(payable(msg.sender), msg.value - totalPrice);
    }

    /// @notice Hawk diff (2): registers a name, paying the flat USD price in
    ///         USDC. Requires prior approval for at least the total price.
    ///
    /// @param registration The registration to register.
    /// @param maxTotalUSDC Upper bound on the USDC charged (base + premium).
    function registerWithUSDC(
        Registration calldata registration,
        uint256 maxTotalUSDC
    ) public override nonReentrant {
        bytes32 labelhash = keccak256(bytes(registration.label));
        IPriceOracle.Price memory price = _rentPriceUSDC(
            registration.label,
            labelhash,
            registration.duration
        );
        uint256 totalPrice = price.base + price.premium;
        if (totalPrice > maxTotalUSDC)
            revert MaxPriceExceeded(totalPrice, maxTotalUSDC);

        usdc.safeTransferFrom(msg.sender, address(this), totalPrice);
        emit USDCPayment(labelhash, msg.sender, totalPrice);

        _register(registration, labelhash, price);
    }

    /// @notice Renews a name, paying in ETH.
    ///
    /// @param label The label of the name.
    /// @param duration The duration of the registration.
    /// @param referrer The referrer of the registration.
    function renew(
        string calldata label,
        uint256 duration,
        bytes32 referrer
    ) external payable override nonReentrant {
        bytes32 labelhash = keccak256(bytes(label));

        IPriceOracle.Price memory price = _rentPrice(
            label,
            labelhash,
            duration
        );
        if (msg.value < price.base) revert InsufficientValue();

        _renew(label, labelhash, duration, referrer, price.base);

        if (msg.value > price.base)
            Address.sendValue(payable(msg.sender), msg.value - price.base);
    }

    /// @notice Hawk diff (2): renews a name, paying the flat USD price in
    ///         USDC. Renewals never pay premiums, matching the ETH path.
    ///
    /// @param label The label of the name.
    /// @param duration The duration of the registration.
    /// @param referrer The referrer of the renewal.
    /// @param maxTotalUSDC Upper bound on the USDC charged.
    function renewWithUSDC(
        string calldata label,
        uint256 duration,
        bytes32 referrer,
        uint256 maxTotalUSDC
    ) external override nonReentrant {
        bytes32 labelhash = keccak256(bytes(label));

        IPriceOracle.Price memory price = _rentPriceUSDC(
            label,
            labelhash,
            duration
        );
        if (price.base > maxTotalUSDC)
            revert MaxPriceExceeded(price.base, maxTotalUSDC);

        usdc.safeTransferFrom(msg.sender, address(this), price.base);
        emit USDCPayment(labelhash, msg.sender, price.base);

        _renew(label, labelhash, duration, referrer, price.base);
    }

    /// @notice Withdraws the ETH balance of the contract to the owner.
    function withdraw() public {
        Address.sendValue(payable(owner()), address(this).balance);
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceID
    ) public view override returns (bool) {
        return
            interfaceID == type(IETHRegistrarController).interfaceId ||
            interfaceID == type(IHawkRegistrarController).interfaceId ||
            super.supportsInterface(interfaceID);
    }

    /* Internal functions */

    /// @dev The upstream registration body (availability, commitment checks,
    ///      registrar + registry + resolver + reverse wiring, event), shared
    ///      by both payment paths. Payment is checked/taken by the caller
    ///      before this runs; ETH refunds happen after it returns.
    function _register(
        Registration calldata registration,
        bytes32 labelhash,
        IPriceOracle.Price memory price
    ) internal {
        // Hawk diff (4): moved from makeCommitment (see note there).
        if (registration.duration < MIN_REGISTRATION_DURATION)
            revert DurationTooShort(registration.duration);
        if (registration.duration > MAX_REGISTRATION_DURATION)
            revert DurationTooLong(registration.duration);

        if (!_available(registration.label, labelhash))
            revert NameNotAvailable(registration.label);

        bytes32 commitment = makeCommitment(registration);
        uint256 commitmentTimestamp = commitments[commitment];

        // Require an old enough commitment.
        if (commitmentTimestamp + minCommitmentAge > block.timestamp)
            revert CommitmentTooNew(
                commitment,
                commitmentTimestamp + minCommitmentAge,
                block.timestamp
            );

        // If the commitment is too old, or the name is registered, stop
        if (commitmentTimestamp + maxCommitmentAge <= block.timestamp) {
            if (commitmentTimestamp == 0) revert CommitmentNotFound(commitment);
            revert CommitmentTooOld(
                commitment,
                commitmentTimestamp + maxCommitmentAge,
                block.timestamp
            );
        }

        delete (commitments[commitment]);

        uint256 expires;

        if (registration.resolver == address(0)) {
            // Hawk diff (5): record the plaintext label for on-chain metadata.
            expires = base.registerWithLabel(
                registration.label,
                registration.owner,
                registration.duration
            );
        } else {
            expires = base.registerWithLabel(
                registration.label,
                address(this),
                registration.duration
            );

            bytes32 namehash = keccak256(
                abi.encodePacked(HAWK_NODE, labelhash)
            );
            ens.setRecord(
                namehash,
                registration.owner,
                registration.resolver,
                0
            );
            if (registration.data.length > 0)
                Resolver(registration.resolver).multicallWithNodeCheck(
                    namehash,
                    registration.data
                );

            base.transferFrom(
                address(this),
                registration.owner,
                uint256(labelhash)
            );

            if (registration.reverseRecord & REVERSE_RECORD_ETHEREUM_BIT != 0)
                reverseRegistrar.setNameForAddr(
                    msg.sender,
                    msg.sender,
                    registration.resolver,
                    string.concat(registration.label, ".hawk")
                );
            if (registration.reverseRecord & REVERSE_RECORD_DEFAULT_BIT != 0)
                defaultReverseRegistrar.setNameForAddr(
                    msg.sender,
                    string.concat(registration.label, ".hawk")
                );
        }

        emit NameRegistered(
            registration.label,
            labelhash,
            registration.owner,
            price.base,
            price.premium,
            expires,
            registration.referrer
        );
    }

    /// @dev The upstream renewal body, shared by both payment paths.
    function _renew(
        string calldata label,
        bytes32 labelhash,
        uint256 duration,
        bytes32 referrer,
        uint256 cost
    ) internal {
        // Hawk diff (4)
        if (duration > MAX_REGISTRATION_DURATION)
            revert DurationTooLong(duration);

        // Hawk diff (7): renew through the wrapper so wrapped names' fuse
        // expiries stay in sync; passes through for unwrapped names.
        uint256 expires = wrapper.renew(uint256(labelhash), duration);

        emit NameRenewed(label, labelhash, cost, expires, referrer);
    }

    function _rentPrice(
        string calldata label,
        bytes32 labelhash,
        uint256 duration
    ) internal view returns (IPriceOracle.Price memory price) {
        price = prices.price(
            label,
            base.nameExpires(uint256(labelhash)),
            duration
        );
    }

    /// @dev Hawk diff (2): USD price converted to USDC base units, rounded up.
    function _rentPriceUSDC(
        string calldata label,
        bytes32 labelhash,
        uint256 duration
    ) internal view returns (IPriceOracle.Price memory price) {
        IPriceOracle.Price memory usdPrice = prices.priceInUSD(
            label,
            base.nameExpires(uint256(labelhash)),
            duration
        );
        price.base = Math.ceilDiv(usdPrice.base, usdcUnitScale);
        price.premium = Math.ceilDiv(usdPrice.premium, usdcUnitScale);
    }

    function _available(
        string calldata label,
        bytes32 labelhash
    ) internal view returns (bool) {
        return
            valid(label) &&
            // Hawk diff (3)
            !reservedList.isLabelhashReserved(labelhash) &&
            base.available(uint256(labelhash));
    }
}
