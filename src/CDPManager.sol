// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "solmate/src/utils/SafeTransferLib.sol";
import "chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import "./CryptoIndexToken.sol";

contract CDPManager {
    using SafeTransferLib for ERC20;

    bool public initialized;

    ERC20 public immutable usdc;
    CryptoIndexToken public cit;
    AggregatorV3Interface public immutable oracle;
    address public hookContract;

    uint256 public constant COLLATERALIZATION_RATIO = 150; // 150%
    uint256 public constant LIQUIDATION_THRESHOLD = 130; // 130%
    uint256 public constant PERCENT_BASE = 100;

    struct Position {
        uint256 collateral; // Amount of USDC deposited
        uint256 debt; // Amount of CIT minted
    }

    mapping(address => Position) public positions;

    constructor(address _usdc, address _oracle, address _hookContract) {
        usdc = ERC20(_usdc);
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

        cit = CryptoIndexToken(addr);
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

    // Function to deposit USDC and mint CIT
    function mintAndDeposit(
        address user,
        address poolManager,
        uint256 usdcAmount
    ) external returns (uint256) {
        require(msg.sender == hookContract, "Only hook can call");
        require(usdcAmount > 0, "Invalid amount");

        // Get CIT price from oracle
        uint256 citPrice = getLatestPrice();

        uint256 collateralAmount = usdcAmount / 2; // 50% to be collateral


        // Calculate CIT amount to mint based on collateral ratio
        uint256 citAmount = (collateralAmount * PERCENT_BASE * 1e18) /
            (citPrice * COLLATERALIZATION_RATIO);

        // Update user's position
        positions[user].debt += citAmount;
        positions[user].collateral += usdcAmount;

        // Mint CIT
        cit.mint(poolManager, citAmount);

        // Transfer
        usdc.transferFrom(user, poolManager, usdcAmount);
        return citAmount;
    }

    // Function to redeem CIT for USDC
    function redeem(uint256 citAmount) external {
        require(citAmount > 0, "Invalid amount");

        // Fetch the current CIT price
        uint256 citPrice = getLatestPrice();

        // Calculate equivalent USDC amount
        uint256 usdcAmount = (citAmount * citPrice) / 1e18;

        // Update user's position
        positions[msg.sender].collateral -= usdcAmount;
        positions[msg.sender].debt -= citAmount;

        // Burn CIT from user
        cit.burnFrom(msg.sender, citAmount);

        // Transfer USDC back to user
        usdc.safeTransfer(msg.sender, usdcAmount);
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
        uint256 citPrice = getLatestPrice();
        uint256 collateralValue = (userPosition.collateral * 1e18);
        uint256 debtValue = userPosition.debt * citPrice;

        uint256 collateralRatio = (collateralValue * PERCENT_BASE) / debtValue;

        require(collateralRatio < LIQUIDATION_THRESHOLD, "Position is healthy");

        // Seize collateral
        uint256 seizedCollateral = userPosition.collateral;

        // Delete user's position
        delete positions[user];

        // Reward liquidator with collateral
        usdc.safeTransfer(msg.sender, seizedCollateral);
    }

    function depositAndMintFromHook(address user, uint256 usdcAmount) external {
        // require(msg.sender == address(hookContract), "Unauthorized"); // Replace hookContract with the actual hook contract address set during deployment.

        require(usdcAmount > 0, "Invalid amount");

        // USDC is already transferred to CDPManager via the pool

        // Fetch the current CIT price
        uint256 citPrice = getLatestPrice();

        // Calculate max CIT mintable based on collateralization ratio
        uint256 citAmount = (usdcAmount * PERCENT_BASE * 1e18) /
            (citPrice * COLLATERALIZATION_RATIO);

        // Update user's position
        positions[user].collateral += usdcAmount;
        positions[user].debt += citAmount;

        // Mint CIT to user
        cit.mint(user, citAmount);
    }

    function setHookContract(address _hookContract) external {
        require(hookContract == address(0), "Hook contract already set");
        hookContract = _hookContract;
    }
}
