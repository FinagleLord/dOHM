// SPDX-License-Identifier: WTFPL
pragma solidity >=0.8.0;

interface IStaking {
    
    struct Epoch {
        uint length;
        uint number;
        uint endBlock;
        uint distribute;
    }

    function epoch() external view returns (Epoch memory);
}