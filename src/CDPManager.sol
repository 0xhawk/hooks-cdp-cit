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

    modifier onlyHookContract() {
        require(msg.sender == hookContract, "Only hook can call");
        _;
    }

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

    function getBytecodeHash(bytes memory bytecode) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytecode));
    }

    function computeAddress(bytes32 salt, bytes32 bytecodeHash) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }

    function mintForCollateral(address recipient, address user, uint256 _collateralAmount)
        external
        onlyHookContract
        returns (uint256)
    {
        require(_collateralAmount > 0, "Invalid collateral amount");

        uint256 syntheticTokenPrice = getLatestPrice();
        require(syntheticTokenPrice > 0, "Invalid oracle price");

        uint256 collateralAmount = _collateralAmount / 2;
        uint256 syntheticTokenAmount =
            (collateralAmount * PERCENT_BASE * 1e18) / (syntheticTokenPrice * COLLATERALIZATION_RATIO);

        positions[user].debt += syntheticTokenAmount;
        positions[user].collateral += collateralAmount;

        syntheticToken.mint(recipient, syntheticTokenAmount);
        return syntheticTokenAmount;
    }

    function onRedeem(address user, uint256 citAmount) external returns (uint256 usdcAmount) {
        require(msg.sender == hookContract, "Only hook");
        Position storage pos = positions[user];
        require(pos.debt >= citAmount, "Not enough debt");

        uint256 price = getLatestPrice();
        usdcAmount = (citAmount * price) / 1e18;
        require(pos.collateral >= usdcAmount, "Not enough collateral");

        pos.debt -= citAmount;
        pos.collateral -= usdcAmount;

        return usdcAmount;
    }

    // function redeem(uint256 syntheticTokenAmount) external {
    //     require(syntheticTokenAmount > 0, "Invalid amount");
    //     Position storage pos = positions[msg.sender];
    //     require(pos.debt >= syntheticTokenAmount, "Not enough debt");

    //     uint256 syntheticTokenPrice = getLatestPrice();
    //     uint256 usdcToReturn = (syntheticTokenAmount * syntheticTokenPrice) /
    //         1e18;

    //     require(pos.collateral >= usdcToReturn, "Not enough collateral");

    //     pos.debt -= syntheticTokenAmount;
    //     pos.collateral -= usdcToReturn;

    //     syntheticToken.burnFrom(msg.sender, syntheticTokenAmount);
    //     collateralToken.safeTransfer(msg.sender, usdcToReturn);
    // }

    // Function to get the latest price from the oracle
    function getLatestPrice() public view returns (uint256) {
        (, int256 price,,,) = oracle.latestRoundData();
        require(price > 0, "Invalid price");
        return uint256(price);
    }

    // Function to liquidate undercollateralized positions
    function liquidate(address user) external {
        Position memory userPosition = positions[user];
        require(userPosition.debt > 0, "No debt");

        uint256 syntheticTokenPrice = getLatestPrice();
        uint256 collateralValue = userPosition.collateral * 1e18;
        uint256 debtValue = userPosition.debt * syntheticTokenPrice;

        uint256 collateralRatio = (collateralValue * PERCENT_BASE) / debtValue;
        require(collateralRatio < LIQUIDATION_THRESHOLD, "Position is healthy");

        uint256 seizedCollateral = userPosition.collateral;
        delete positions[user];

        collateralToken.safeTransfer(msg.sender, seizedCollateral);
    }

    function onLiquidate(address victim) external returns (uint256 seizedCollateral) {
        require(msg.sender == hookContract, "Only hook");
        Position memory userPos = positions[victim];
        require(userPos.debt > 0, "No debt");

        uint256 price = getLatestPrice();
        uint256 collateralValue = userPos.collateral * 1e18;
        uint256 debtValue = userPos.debt * price;
        uint256 ratio = (collateralValue * PERCENT_BASE) / debtValue;
        require(ratio < LIQUIDATION_THRESHOLD, "Position is healthy");

        seizedCollateral = userPos.collateral;
        delete positions[victim];
        return seizedCollateral;
    }

    function setHookContract(address _hookContract) external {
        require(hookContract == address(0), "Hook contract already set");
        hookContract = _hookContract;
    }
}
