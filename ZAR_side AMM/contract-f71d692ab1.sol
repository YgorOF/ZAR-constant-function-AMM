// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

//take in 2 tokens, both ERC20. We first import IERC20 interface. We then create the 2 totokens we will use

contract CPAMM {
    IERC20 public immutable tokenZAR;
    IERC20 public immutable tokenUSDC;

//state variables "uint" will keep track of the volume of tokens in each contract
    uint public reserveZAR;
    uint public reserveUSDC;

    uint public totalSupply;
    mapping(address => uint) public balanceOf;

    constructor(address _tokenZAR, address _tokenUSDC) {
        tokenZAR = IERC20(_tokenZAR);
        tokenUSDC = IERC20(_tokenUSDC);
    }
//need an internal function to mint/burn shares, comprised of blalance & supply increments. 
//This is set to "private" as its an internal function.
    function _mint(address _to, uint _amount) private {
        balanceOf[_to] += _amount;
        totalSupply += _amount;
    }

    function _burn(address _from, uint _amount) private {
        balanceOf[_from] -= _amount;
        totalSupply -= _amount;
    }

    function _update(uint _reserveZAR, uint _reserveUSDC) private {
        reserveZAR = _reserveZAR;
        reserveUSDC = _reserveUSDC;
    }
//now we need a trade function that Users can call externally
    function swap(address _tokenIn, uint _amountIn) external returns (uint amountOut) {
        require(
            _tokenIn == address(tokenZAR) || _tokenIn == address(tokenUSDC),
            "invalid token"
        );
        require(_amountIn > 0, "amount in = 0");

        bool isTokenZAR = _tokenIn == address(tokenZAR);
        (IERC20 tokenIn, IERC20 tokenOut, uint reserveIn, uint reserveOut) = isTokenZAR
            ? (tokenZAR, tokenUSDC, reserveZAR, reserveUSDC)
            : (tokenUSDC, tokenZAR, reserveUSDC, reserveZAR);

        tokenIn.transferFrom(msg.sender, address(this), _amountIn);

        /*
        How much dy for dx?

        xy = k
        (x + dx)(y - dy) = k
        y - dy = k / (x + dx)
        y - k / (x + dx) = dy
        y - xy / (x + dx) = dy
        (yx + ydx - xy) / (x + dx) = dy
        ydx / (x + dx) = dy
        */
        // 0.3% fee so this is excluded from the amount you put in
        uint amountInWithFee = (_amountIn * 997) / 1000;
        amountOut = (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee);

        tokenOut.transfer(msg.sender, amountOut);

        _update(tokenZAR.balanceOf(address(this)), tokenUSDC.balanceOf(address(this)));
    }

//By "adding liquidity" we also mint shares for that User. These Users = LPs
//The user is able to provide 2 tpyes of token into this function
//By removing liquidity, LPs also remove the fees they've earned from that liquidity
    function addLiquidity(uint _amount0, uint _amount1) external returns (uint shares) {
        tokenZAR.transferFrom(msg.sender, address(this), _amount0);
        tokenUSDC.transferFrom(msg.sender, address(this), _amount1);

        /*
        How much dx, dy to add?

        xy = k
        (x + dx)(y + dy) = k'

        No price change, before and after adding liquidity
        x / y = (x + dx) / (y + dy)

        x(y + dy) = y(x + dx)
        x * dy = y * dx

        x / y = dx / dy
        dy = y / x * dx
        */
        if (reserveZAR > 0 || reserveUSDC > 0) {
            require(reserveZAR * _amount1 == reserveUSDC * _amount0, "x / y != dx / dy; we can not change value of constant");
        }

        /*
        How much shares to mint?

        f(x, y) = value of liquidity
        We will define f(x, y) = sqrt(xy)

        L0 = f(x, y)
        L1 = f(x + dx, y + dy)
        T = total shares
        s = shares to mint

        Total shares should increase proportional to increase in liquidity
        L1 / L0 = (T + s) / T

        L1 * T = L0 * (T + s)

        (L1 - L0) * T / L0 = s 
        */

        /*
        Claim
        (L1 - L0) / L0 = dx / x = dy / y

        Proof
        --- Equation 1 ---
        (L1 - L0) / L0 = (sqrt((x + dx)(y + dy)) - sqrt(xy)) / sqrt(xy)
        
        dx / dy = x / y so replace dy = dx * y / x

        --- Equation 2 ---
        Equation 1 = (sqrt(xy + 2ydx + dx^2 * y / x) - sqrt(xy)) / sqrt(xy)

        Multiply by sqrt(x) / sqrt(x)
        Equation 2 = (sqrt(x^2y + 2xydx + dx^2 * y) - sqrt(x^2y)) / sqrt(x^2y)
                   = (sqrt(y)(sqrt(x^2 + 2xdx + dx^2) - sqrt(x^2)) / (sqrt(y)sqrt(x^2))
        
        sqrt(y) on top and bottom cancels out

        --- Equation 3 ---
        Equation 2 = (sqrt(x^2 + 2xdx + dx^2) - sqrt(x^2)) / (sqrt(x^2)
        = (sqrt((x + dx)^2) - sqrt(x^2)) / sqrt(x^2)  
        = ((x + dx) - x) / x
        = dx / x

        Since dx / dy = x / y,
        dx / x = dy / y

        Finally
        (L1 - L0) / L0 = dx / x = dy / y
        */
        if (totalSupply == 0) {
            shares = _sqrt(_amount0 * _amount1);
        } else {
            shares = _min(
                (_amount0 * totalSupply) / reserveZAR,
                (_amount1 * totalSupply) / reserveUSDC
            );
        }
        require(shares > 0, "shares = 0");
        _mint(msg.sender, shares);

        _update(tokenZAR.balanceOf(address(this)), tokenUSDC.balanceOf(address(this)));
    }

    function removeLiquidity(
        uint _shares
    ) external returns (uint amount0, uint amount1) {
        /*
        Claim
        dx, dy = amount of liquidity to remove
        dx = s / T * x
        dy = s / T * y

        Proof
        Let's find dx, dy such that
        v / L = s / T
        
        where
        v = f(dx, dy) = sqrt(dxdy)
        L = total liquidity = sqrt(xy)
        s = shares
        T = total supply

        --- Equation 1 ---
        v = s / T * L
        sqrt(dxdy) = s / T * sqrt(xy)

        Amount of liquidity to remove must not change price so 
        dx / dy = x / y

        replace dy = dx * y / x
        sqrt(dxdy) = sqrt(dx * dx * y / x) = dx * sqrt(y / x)

        Divide both sides of Equation 1 with sqrt(y / x)
        dx = s / T * sqrt(xy) / sqrt(y / x)
           = s / T * sqrt(x^2) = s / T * x

        Likewise
        dy = s / T * y
        */

        // bal0 >= reserveZAR
        // bal1 >= reserveUSDC
        uint bal0 = tokenZAR.balanceOf(address(this));
        uint bal1 = tokenUSDC.balanceOf(address(this));

        amount0 = (_shares * bal0) / totalSupply;
        amount1 = (_shares * bal1) / totalSupply;
        require(amount0 > 0 && amount1 > 0, "amount0 or amount1 = 0");

        _burn(msg.sender, _shares);
        _update(bal0 - amount0, bal1 - amount1);

        tokenZAR.transfer(msg.sender, amount0);
        tokenUSDC.transfer(msg.sender, amount1);
    }

    function _sqrt(uint y) private pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _min(uint x, uint y) private pure returns (uint) {
        return x <= y ? x : y;
    }
}

interface IERC20 {
    function totalSupply() external view returns (uint);

    function balanceOf(address account) external view returns (uint);

    function transfer(address recipient, uint amount) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint amount) external returns (bool);

    function transferFrom(
        address sender,
        address recipient,
        uint amount
    ) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint amount);
    event Approval(address indexed owner, address indexed spender, uint amount);
}


