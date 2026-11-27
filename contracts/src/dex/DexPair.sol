// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

/// @title DexPair
/// @notice Constant-product (x*y=k) pair with a Uniswap-V2-style interface. The pair is its own LP token.
///         Swap fee is 25 bps and stays in the pool for LPs; `swap` enforces fee-adjusted k:
///         (bal0*10000 - in0*25) * (bal1*10000 - in1*25) >= r0 * r1 * 10000^2.
/// @dev    No flash-swap callback, no protocol fee, no TWAP accumulators: smallest surface that is a real AMM.
contract DexPair {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint256 public constant FEE_BPS = 25;
    uint256 private constant BPS = 10_000;

    // ----------------------------------------------------------------- LP token
    string public constant name = "Bushido DEX LP";
    string public constant symbol = "BDX-LP";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // --------------------------------------------------------------------- pair
    address public immutable factory;
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    uint256 private unlocked = 1;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    error Locked();
    error Forbidden();
    error AlreadyInitialized();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InsufficientLiquidity();
    error InvalidTo();
    error K();
    error Overflow();
    error TransferFailed();

    modifier lock() {
        if (unlocked != 1) revert Locked();
        unlocked = 0;
        _;
        unlocked = 1;
    }

    constructor() {
        factory = msg.sender;
    }

    function initialize(address _token0, address _token1) external {
        if (msg.sender != factory) revert Forbidden();
        if (token0 != address(0)) revert AlreadyInitialized();
        token0 = _token0;
        token1 = _token1;
    }

    function getReserves() public view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    // ------------------------------------------------------------------ ERC-20
    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transferLp(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - value;
        _transferLp(from, to, value);
        return true;
    }

    // ------------------------------------------------------------- liquidity
    /// @notice Mint LP for tokens already sent to the pair (the router sends them first).
    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 r0, uint112 r1,) = getReserves();
        uint256 b0 = IERC20Min(token0).balanceOf(address(this));
        uint256 b1 = IERC20Min(token1).balanceOf(address(this));
        uint256 a0 = b0 - r0;
        uint256 a1 = b1 - r1;

        uint256 supply = totalSupply;
        if (supply == 0) {
            liquidity = _sqrt(a0 * a1) - MINIMUM_LIQUIDITY; // underflow reverts on dust
            _mintLp(address(0xdead), MINIMUM_LIQUIDITY); // permanently locked, prevents share inflation
        } else {
            uint256 l0 = (a0 * supply) / r0;
            uint256 l1 = (a1 * supply) / r1;
            liquidity = l0 < l1 ? l0 : l1;
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mintLp(to, liquidity);
        _update(b0, b1);
        emit Mint(msg.sender, a0, a1);
    }

    /// @notice Burn LP already sent to the pair and pay out the pro-rata share of both tokens.
    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        address t0 = token0;
        address t1 = token1;
        uint256 b0 = IERC20Min(t0).balanceOf(address(this));
        uint256 b1 = IERC20Min(t1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];
        uint256 supply = totalSupply;

        amount0 = (liquidity * b0) / supply;
        amount1 = (liquidity * b1) / supply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();
        _burnLp(address(this), liquidity);
        _safeTransfer(t0, to, amount0);
        _safeTransfer(t1, to, amount1);
        _update(IERC20Min(t0).balanceOf(address(this)), IERC20Min(t1).balanceOf(address(this)));
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // ------------------------------------------------------------------- swap
    /// @notice Send out the requested amounts; input must already be in the pair. Reverts unless fee-adjusted k holds.
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external lock {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        (uint112 r0, uint112 r1,) = getReserves();
        if (amount0Out >= r0 || amount1Out >= r1) revert InsufficientLiquidity();

        address t0 = token0;
        address t1 = token1;
        if (to == t0 || to == t1) revert InvalidTo();
        if (amount0Out > 0) _safeTransfer(t0, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(t1, to, amount1Out);
        uint256 b0 = IERC20Min(t0).balanceOf(address(this));
        uint256 b1 = IERC20Min(t1).balanceOf(address(this));

        (uint256 in0, uint256 in1) = _checkK(b0, b1, r0 - amount0Out, r1 - amount1Out, uint256(r0) * r1);
        _update(b0, b1);
        emit Swap(msg.sender, in0, in1, amount0Out, amount1Out, to);
    }

    /// @dev `left0/1` = reserves minus amounts sent out; anything above that in the balance is input.
    function _checkK(uint256 b0, uint256 b1, uint256 left0, uint256 left1, uint256 kBefore)
        private
        pure
        returns (uint256 in0, uint256 in1)
    {
        in0 = b0 > left0 ? b0 - left0 : 0;
        in1 = b1 > left1 ? b1 - left1 : 0;
        if (in0 == 0 && in1 == 0) revert InsufficientInputAmount();
        uint256 adj0 = b0 * BPS - in0 * FEE_BPS;
        uint256 adj1 = b1 * BPS - in1 * FEE_BPS;
        if (adj0 * adj1 < kBefore * BPS * BPS) revert K();
    }

    /// @notice Send any balance above the reserves to `to`.
    function skim(address to) external lock {
        address t0 = token0;
        address t1 = token1;
        _safeTransfer(t0, to, IERC20Min(t0).balanceOf(address(this)) - reserve0);
        _safeTransfer(t1, to, IERC20Min(t1).balanceOf(address(this)) - reserve1);
    }

    /// @notice Set the reserves to the current balances.
    function sync() external lock {
        _update(IERC20Min(token0).balanceOf(address(this)), IERC20Min(token1).balanceOf(address(this)));
    }

    // --------------------------------------------------------------- internal
    function _update(uint256 b0, uint256 b1) private {
        if (b0 > type(uint112).max || b1 > type(uint112).max) revert Overflow();
        reserve0 = uint112(b0);
        reserve1 = uint112(b1);
        blockTimestampLast = uint32(block.timestamp);
        emit Sync(reserve0, reserve1);
    }

    function _mintLp(address to, uint256 v) private {
        totalSupply += v;
        balanceOf[to] += v;
        emit Transfer(address(0), to, v);
    }

    function _burnLp(address from, uint256 v) private {
        balanceOf[from] -= v;
        totalSupply -= v;
        emit Transfer(from, address(0), v);
    }

    function _transferLp(address from, address to, uint256 v) private {
        balanceOf[from] -= v;
        balanceOf[to] += v;
        emit Transfer(from, to, v);
    }

    function _safeTransfer(address token, address to, uint256 v) private {
        if (v == 0) return;
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, v));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
