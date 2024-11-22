// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "solmate/src/utils/SafeTransferLib.sol";
import "chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import "./CryptoIndexToken.sol";

contract CDPManager {
    using SafeTransferLib for ERC20;

    ERC20 public immutable usdc;
    CryptoIndexToken public immutable cit;
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

    constructor(address _usdc, address _cit, address _oracle) {
        usdc = ERC20(_usdc);
        cit = CryptoIndexToken(_cit);
        oracle = AggregatorV3Interface(_oracle);
    }

    // Function to deposit USDC and mint CIT
    function depositAndMint(uint256 usdcAmount) external {
        require(usdcAmount > 0, "Invalid amount");

        // Transfer USDC from user to contract
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Fetch the current CIT price
        uint256 citPrice = getLatestPrice();

        // Calculate max CIT mintable based on collateralization ratio
        uint256 citAmount = (usdcAmount * PERCENT_BASE * 1e18) /
            (citPrice * COLLATERALIZATION_RATIO);

        // Update user's position
        positions[msg.sender].collateral += usdcAmount;
        positions[msg.sender].debt += citAmount;

        // Mint CIT to user
        cit.mint(msg.sender, citAmount);
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
