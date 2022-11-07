//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

contract Params {

    // enum for validator state
    enum State {
        Idle,
        Ready,
        Jail,
        Exit
    }
    // enum to showing what ranking operation should be done
    enum RankingOp {
        Noop,
        Up,
        Down,
        Remove
    }
}
