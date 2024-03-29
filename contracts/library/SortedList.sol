// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.4;

import "../interfaces/IValidator.sol";

library SortedLinkedList {
    struct List {
        IValidator head;
        IValidator tail;
        uint8 length;
        mapping(IValidator => IValidator) prev;
        mapping(IValidator => IValidator) next;
    }

    function improveRanking(List storage _list, IValidator _value)
    internal {
        //insert new
        if (_list.length == 0) {
            _list.head = _value;
            _list.tail = _value;
            _list.length++;
            return;
        }

        //already first
        if (_list.head == _value) {
            return;
        }

        IValidator _prev = _list.prev[_value];
        uint _totalStake = _value.TotalStake();
        // not in list
        if (_prev == IValidator(address(0))) {
            if (_list.length >= 100) {
                if (_totalStake <= _list.tail.TotalStake()){
                    return;
                }
                _list.tail = _list.prev[_list.tail];
                _list.next[_list.tail] = IValidator(address(0));
                _list.length--;
            }

            //insert new
            _list.length++;

            if (_totalStake <= _list.tail.TotalStake()) {
                _list.prev[_value] = _list.tail;
                _list.next[_list.tail] = _value;
                _list.tail = _value;

                return;
            }

            _prev = _list.tail;
        } else {
            if (_totalStake <= _prev.TotalStake()) {
                return;
            }

            //remove from list
            _list.next[_prev] = _list.next[_value];
            if (_value == _list.tail) {
                _list.tail = _prev;
            } else {
                _list.prev[_list.next[_value]] = _list.prev[_value];
            }
        }

        while (_prev != IValidator(address(0)) && _totalStake > _prev.TotalStake()) {
            _prev = _list.prev[_prev];
        }

        if (_prev == IValidator(address(0))) {
            _list.next[_value] = _list.head;
            _list.prev[_list.head] = _value;
            _list.prev[_value] = IValidator(address(0));
            _list.head = _value;
        } else {
            _list.next[_value] = _list.next[_prev];
            _list.prev[_list.next[_prev]] = _value;
            _list.next[_prev] = _value;
            _list.prev[_value] = _prev;
        }
    }


    function lowerRanking(List storage _list, IValidator _value)
    internal {
        IValidator _next = _list.next[_value];
        uint _totalStake = _value.TotalStake();
        if (_list.tail == _value || _next == IValidator(address(0)) || _next.TotalStake() <= _totalStake) {
            return;
        }

        //remove it
        _list.prev[_next] = _list.prev[_value];
        if (_list.head == _value) {
            _list.head = _next;
        } else {
            _list.next[_list.prev[_value]] = _next;
        }

        while (_next != IValidator(address(0)) && _next.TotalStake() > _totalStake) {
            _next = _list.next[_next];
        }

        if (_next == IValidator(address(0))) {
            _list.prev[_value] = _list.tail;
            _list.next[_value] = IValidator(address(0));

            _list.next[_list.tail] = _value;
            _list.tail = _value;
        } else {
            _list.next[_list.prev[_next]] = _value;
            _list.prev[_value] = _list.prev[_next];
            _list.next[_value] = _next;
            _list.prev[_next] = _value;
        }
    }


    function removeRanking(List storage _list, IValidator _value)
    internal {
        if (_list.head != _value && _list.prev[_value] == IValidator(address(0))) {
            //not in list
            return;
        }

        if (_list.tail == _value) {
            _list.tail = _list.prev[_value];
        }

        if (_list.head == _value) {
            _list.head = _list.next[_value];
        }

        IValidator _next = _list.next[_value];
        if (_next != IValidator(address(0))) {
            _list.prev[_next] = _list.prev[_value];
        }
        IValidator _prev = _list.prev[_value];
        if (_prev != IValidator(address(0))) {
            _list.next[_prev] = _list.next[_value];
        }

        _list.prev[_value] = IValidator(address(0));
        _list.next[_value] = IValidator(address(0));
        _list.length--;
    }
}
