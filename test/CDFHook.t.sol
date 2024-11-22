// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import "../src/CryptoIndexToken.sol";
import "../src/CDPManager.sol";
import "../src/CDPHook.sol";
import "v4-core/PoolManager.sol";
import "v4-core/interfaces/IPoolManager.sol";
import "v4-core/types/Currency.sol";
import "v4-core/types/PoolKey.sol";
import "v4-core/libraries/TickMath.sol";
import "solmate/src/tokens/ERC20.sol";
import "solmate/src/test/utils/mocks/MockERC20.sol";
import "chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract CDPSystemTest is Test, Deployers {
    MockERC20 usdc;
    CryptoIndexToken cit;
    CDPManager cdpManager;
    CDPHook hook;
    PoolManager poolManager;
    IPoolManager.SwapParams swapParams;
    Currency usdcCurrency;
    Currency citCurrency;
    PoolKey poolKey;
    MockV3Aggregator oracle;

    function setUp() public {
        // Deploy USDC Mock Token
        usdc = new MockERC20("Mock USDC", "USDC", 6);

        // Deploy CIT Token
        cit = new CryptoIndexToken();

        // Deploy Mock Oracle
        oracle = new MockV3Aggregator(18, 2000e18); // Assume CIT price is $2000

        // Deploy CDP Manager
        cdpManager = new CDPManager(
            address(usdc),
            address(cit),
            address(oracle)
        );

        // Set CDP Manager as minter of CIT
        cit.setMinter(address(cdpManager));

        // Deploy Pool Manager using Deployers utility
        deployFreshManagerAndRouters();

        // Deploy Hook
        hook = new CDPHook(poolManager, address(cdpManager), address(cit));

        // Set hook contract in CDP Manager
        cdpManager.setHookContract(address(hook));

        // Initialize Uniswap Pool
        usdcCurrency = Currency.wrap(address(usdc));
        citCurrency = Currency.wrap(address(cit));

        poolKey = PoolKey({
            currency0: usdcCurrency,
            currency1: citCurrency,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0)); // Price 1:1

        // Mint USDC to user
        usdc.mint(address(this), 1000e6);

        // Approve USDC to Pool Manager
        usdc.approve(address(poolManager), 1000e6);
    }

    function testAddLiquidityAndMintCIT() public {
        uint256 usdcAmount = 100e6; // 100 USDC

        // Prepare ModifyLiquidityParams
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager
            .ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int128(1000000),
                salt: bytes32(0)
            });

        // Call modifyLiquidity on Pool Manager
        poolManager.modifyLiquidity(poolKey, params, "");

        // Verify CIT minted to user
        uint256 citBalance = cit.balanceOf(address(this));
        assertTrue(citBalance > 0, "CIT not minted");

        // Capture the returned values
        (uint256 collateral, uint256 debt) = cdpManager.positions(
            address(this)
        );

        // Verify user's position in CDP Manager
        assertEq(collateral, usdcAmount, "Incorrect collateral");
        assertEq(debt, citBalance, "Incorrect debt");
    }
}
