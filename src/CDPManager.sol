// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "solmate/src/utils/SafeTransferLib.sol";
import "chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import "./CryptoIndexToken.sol";

contract CDPManager {
    using SafeTransferLib for ERC20;

    bool public initialized;

    ERC20 public collateralToken;
    CryptoIndexToken public syntheticToken;
    AggregatorV3Interface public immutable oracle;
    address public hookContract;

    uint256 public constant COLLATERALIZATION_RATIO = 150; // 150%
    uint256 public constant LIQUIDATION_THRESHOLD = 130; // 130%
    uint256 public constant PERCENT_BASE = 100;

    struct Position {
        uint256 collateral; // Amount of USDC deposited
        uint256 debt; // Amount of syntheticToken minted
    }

    mapping(address => Position) public positions;

    constructor(address _collateralToken, address _oracle, address _hookContract) {
        collateralToken = ERC20(_collateralToken);
        oracle = AggregatorV3Interface(_oracle);
        hookContract = _hookContract;
    }

    function initialize(bytes32 salt) external {
        require(!initialized, "Already initialized");
        bytes memory bytecode = type(CryptoIndexToken).creationCode;

        address addr;
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(addr != address(0), "Deploy failed");

        syntheticToken = CryptoIndexToken(addr);
        initialized = true;
    }

    function getBytecodeHash(
        bytes memory bytecode
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytecode));
    }

    function computeAddress(
        bytes32 salt,
        bytes32 bytecodeHash
    ) public view returns (address) {
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                bytes1(0xff),
                                address(this),
                                salt,
                                bytecodeHash
                            )
                        )
                    )
                )
            );
    }

    // Function to deposit USDC and mint syntheticToken
    function mintAndDeposit(
        address user,
        address poolManager,
        uint256 _collateralAmount
    ) external returns (uint256) {
        require(msg.sender == hookContract, "Only hook can call");
        require(_collateralAmount > 0, "Invalid amount");

        // Get syntheticToken price from oracle
        uint256 syntheticTokenPrice = getLatestPrice();

        uint256 collateralAmount = _collateralAmount / 2; // 50% to be collateral


        // Calculate syntheticToken amount to mint based on collateral ratio
        uint256 syntheticTokenAmount = (collateralAmount * PERCENT_BASE * 1e18) /
            (syntheticTokenPrice * COLLATERALIZATION_RATIO);

        // Update user's position
        positions[user].debt += syntheticTokenAmount;
        positions[user].collateral += collateralAmount;

        // Mint syntheticToken
        syntheticToken.mint(poolManager, syntheticTokenAmount);

        // Transfer
        collateralToken.transferFrom(user, poolManager, collateralAmount);
        return syntheticTokenAmount;
    }

    // Function to redeem syntheticToken for USDC
    function redeem(uint256 syntheticTokenAmount) external {
        require(syntheticTokenAmount > 0, "Invalid amount");

        // Fetch the current syntheticToken price
        uint256 syntheticTokenPrice = getLatestPrice();

        // Calculate equivalent USDC amount
        uint256 collateralAmount = (syntheticTokenAmount * syntheticTokenPrice) / 1e18;

        // Update user's position
        positions[msg.sender].collateral -= collateralAmount;
        positions[msg.sender].debt -= syntheticTokenAmount;

        // Burn syntheticToken from user
        syntheticToken.burnFrom(msg.sender, syntheticTokenAmount);

        // Transfer USDC back to user
        collateralToken.safeTransfer(msg.sender, collateralAmount);
    }

    // Function to get the latest price from the oracle
    function getLatestPrice() public view returns (uint256) {
        (, int256 price, , , ) = oracle.latestRoundData();
        require(price > 0, "Invalid price");
        return uint256(price);
    }

    // Function to liquidate undercollateralized positions
    function liquidate(address user) external {
        Position memory userPosition = positions[user];
        require(userPosition.debt > 0, "No debt");

        // Calculate collateralization ratio
        uint256 syntheticTokenPrice = getLatestPrice();
        uint256 collateralValue = (userPosition.collateral * 1e18);
        uint256 debtValue = userPosition.debt * syntheticTokenPrice;

        uint256 collateralRatio = (collateralValue * PERCENT_BASE) / debtValue;

        require(collateralRatio < LIQUIDATION_THRESHOLD, "Position is healthy");

        // Seize collateral
        uint256 seizedCollateral = userPosition.collateral;

        // Delete user's position
        delete positions[user];

        // Reward liquidator with collateral
        collateralToken.safeTransfer(msg.sender, seizedCollateral);
    }

    function depositAndMintFromHook(address user, uint256 collateralAmount) external {
        // require(msg.sender == address(hookContract), "Unauthorized"); // Replace hookContract with the actual hook contract address set during deployment.

        require(collateralAmount > 0, "Invalid amount");

        // USDC is already transferred to CDPManager via the pool

        // Fetch the current syntheticToken price
        uint256 syntheticTokenPrice = getLatestPrice();

        // Calculate max syntheticToken mintable based on collateralization ratio
        uint256 syntheticTokenAmount = (collateralAmount * PERCENT_BASE * 1e18) /
            (syntheticTokenPrice * COLLATERALIZATION_RATIO);

        // Update user's position
        positions[user].collateral += collateralAmount;
        positions[user].debt += syntheticTokenAmount;

        // Mint syntheticToken to user
        syntheticToken.mint(user, syntheticTokenAmount);
    }

    function setHookContract(address _hookContract) external {
        require(hookContract == address(0), "Hook contract already set");
        hookContract = _hookContract;
    }
}
