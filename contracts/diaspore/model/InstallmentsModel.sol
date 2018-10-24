pragma solidity ^0.4.24;

import "./../interfaces/Model.sol";
import "./../interfaces/ModelDescriptor.sol";
import "./../../utils/Ownable.sol";
import "./../../utils/BytesUtils.sol";

contract InstallmentsModel is BytesUtils, Ownable, Model, ModelDescriptor {
    mapping(bytes4 => bool) private _supportedInterface;

    constructor() public {
        _supportedInterface[this.owner.selector] = true;
        _supportedInterface[this.validate.selector] = true;
        _supportedInterface[this.getStatus.selector] = true;
        _supportedInterface[this.getPaid.selector] = true;
        _supportedInterface[this.getObligation.selector] = true;
        _supportedInterface[this.getClosingObligation.selector] = true;
        _supportedInterface[this.getDueTime.selector] = true;
        _supportedInterface[this.getFinalTime.selector] = true;
        _supportedInterface[this.getFrequency.selector] = true;
        _supportedInterface[this.getEstimateObligation.selector] = true;
        _supportedInterface[this.addDebt.selector] = true; // ??? Not supported
        _supportedInterface[this.run.selector] = true;
        _supportedInterface[this.fixClock.selector] = true;
        _supportedInterface[this.create.selector] = true;
        _supportedInterface[this.addPaid.selector] = true;
        _supportedInterface[this.configs.selector] = true;
        _supportedInterface[this.states.selector] = true;
        _supportedInterface[this.engine.selector] = true;
    }

    function supportsInterface(bytes4 interfaceId) external view returns (bool) {
        return 
            interfaceId == this.supportsInterface.selector ||
            interfaceId == debtModelInterface ||
            _supportedInterface[interfaceId];
    }

    address public engine;
    address private altDescriptor;

    mapping(bytes32 => Config) public configs;
    mapping(bytes32 => State) public states;

    uint256 public constant L_DATA = 16 + 32 + 3 + 5;

    uint256 private constant U_128_OVERFLOW = 2 ** 128;
    uint256 private constant U_64_OVERFLOW = 2 ** 64;
    uint256 private constant U_40_OVERFLOW = 2 ** 40;
    uint256 private constant U_24_OVERFLOW = 2 ** 24;

    event _setEngine(address _engine);
    event _setDescriptor(address _descriptor);

    event _setClock(bytes32 _id, uint64 _to);
    event _setStatus(bytes32 _id, uint8 _status);
    event _setPaidBase(bytes32 _id, uint128 _paidBase);
    event _setInterest(bytes32 _id, uint128 _interest);

    struct Config {
        uint24 installments;
        uint40 duration;
        uint64 lentTime;
        uint128 cuota;
        uint256 interestRate;
        bytes32 id;
    }

    struct State {
        uint8 status;
        uint64 clock;
        uint64 lastPayment;
        uint128 paid;
        uint128 paidBase;
        uint128 interest;
    }

    modifier onlyEngine {
        require(msg.sender == engine, "Only engine allowed");
        _;
    }

    function modelId() external view returns (bytes32) {
        // InstallmentsModel A 0.0.2
        return 0x496e7374616c6c6d656e74734d6f64656c204120302e302e3200000000000000;
    }

    function descriptor() external view returns (address) {
        address _descriptor = altDescriptor;
        return _descriptor == address(0) ? this : _descriptor;
    }

    function setEngine(address _engine) external onlyOwner returns (bool) {
        engine = _engine;
        emit _setEngine(_engine);
        return true;
    }

    function setDescriptor(address _descriptor) external onlyOwner returns (bool) {
        altDescriptor = _descriptor;
        emit _setDescriptor(_descriptor);
        return true;
    }

    function encodeData(
        uint128 _cuota,
        uint256 _interestRate,
        uint24 _installments,
        uint40 _duration
    ) external pure returns (bytes) {
        return abi.encodePacked(_cuota, _interestRate, _installments, _duration);
    }

    function create(bytes32 id, bytes data) external onlyEngine returns (bool) {
        require(configs[id].cuota == 0, "Entry already exist");
        
        (uint128 cuota, uint256 interestRate, uint24 installments, uint40 duration) = _decodeData(data);
        _validate(cuota, interestRate, installments, duration);

        configs[id] = Config({
            installments: installments,
            duration: duration,
            lentTime: uint64(now),
            cuota: cuota,
            interestRate: interestRate,
            id: id
        });

        states[id].clock = duration;

        emit Created(id);
        emit _setClock(id, duration);

        return true;
    }

    function addPaid(bytes32 id, uint256 amount) external onlyEngine returns (uint256 real) {
        Config storage config = configs[id];
        State storage state = states[id];

        _advanceClock(id, uint64(now) - config.lentTime);

        if (state.status != STATUS_PAID) {
            // State & config memory load
            uint256 paid = state.paid;
            uint256 duration = config.duration;
            uint256 interest = state.interest;

            // Payment aux
            require(available < U_128_OVERFLOW, "Amount overflow");
            uint256 available = amount;

            // Aux variables
            uint256 unpaidInterest;
            uint256 pending;
            uint256 target;
            uint256 baseDebt;
            uint256 clock;

            do {
                clock = state.clock;

                baseDebt = _baseDebt(clock, duration, config.installments, config.cuota);
                pending = baseDebt + interest - paid;

                // min(pending, available)
                target = pending < available ? pending : available;

                // Calc paid base
                unpaidInterest = interest - (paid - state.paidBase);

                // max(target - unpaidInterest, 0)
                state.paidBase += uint128(target > unpaidInterest ? target - unpaidInterest : 0);
                emit _setPaidBase(id, state.paidBase);

                paid += target;
                available -= target;

                // Check fully paid
                // All installments paid + interest
                if (clock / duration >= config.installments && baseDebt + interest <= paid) {
                    // Registry paid!
                    state.status = uint8(STATUS_PAID);
                    emit _setStatus(id, uint8(STATUS_PAID));
                    break;
                }

                // If installment fully paid, advance to next one
                if (pending == target) {
                    _advanceClock(id, clock + duration - (clock % duration));
                }
            } while (available != 0);

            require(paid < U_128_OVERFLOW, "Paid overflow");
            state.paid = uint128(paid);
            state.lastPayment = state.clock;

            real = amount - available;
            emit AddedPaid(id, real);
        }
    }

    function addDebt(bytes32 id, uint256 amount) external onlyEngine returns (bool) {
        revert("Not implemented!");
    }

    function fixClock(bytes32 id, uint64 target) external returns (bool) {
        if (target <= now) {
            Config storage config = configs[id];
            State storage state = states[id];
            uint64 lentTime = config.lentTime;
            require(lentTime >= target, "Clock can't go negative");
            uint64 targetClock = config.lentTime - target;
            require(targetClock > state.clock, "Clock is ahead of target");
            return _advanceClock(id, targetClock);
        }
    }

    function isOperator(address _target) external view returns (bool) {
        return engine == _target;
    }

    function getStatus(bytes32 id) external view returns (uint256) {
        Config storage config = configs[id];
        State storage state = states[id];
        require(config.lentTime != 0, "The registry does not exist");
        return state.status == STATUS_PAID ? STATUS_PAID : STATUS_ONGOING;
    }

    function getPaid(bytes32 id) external view returns (uint256) {
        return states[id].paid;
    }

    function getObligation(bytes32 id, uint64 timestamp) external view returns (uint256, bool) {
        State storage state = states[id];
        Config storage config = configs[id];

        // Can't be before creation
        if (timestamp < config.lentTime) {
            return (0, true);
        } 

        // Static storage loads        
        uint256 currentClock = timestamp - config.lentTime;

        uint256 base = _baseDebt(
            currentClock,
            config.duration,
            config.installments,
            config.cuota
        );

        uint256 interest;
        uint256 prevInterest = state.interest;
        uint256 clock = state.clock;
        bool defined;

        if (clock >= currentClock) {
            interest = prevInterest;
            defined = true;
        } else {
            // We need to calculate the new interest, on a view!
            (interest, currentClock) = _runAdvanceClock({
                _clock: clock,
                _interest: prevInterest,
                _duration: config.duration,
                _cuota: config.cuota,
                _installments: config.installments,
                _paidBase: state.paidBase,
                _interestRate: config.interestRate,
                _targetClock: currentClock
            });

            defined = prevInterest == interest;
        }
        
        uint256 debt = base + interest;
        uint256 paid = state.paid;
        return (debt > paid ? debt - paid : 0, defined);
    }

    function run(bytes32 id) external returns (bool) {
        Config storage config = configs[id];
        return _advanceClock(id, uint64(now) - config.lentTime);
    }

    function validate(bytes data) external view returns (bool) {
        (uint128 cuota, uint256 interestRate, uint24 installments, uint40 duration) = _decodeData(data);
        _validate(cuota, interestRate, installments, duration);
        return true;
    }

    function getClosingObligation(bytes32 id) external view returns (uint256) {
        return _getClosingObligation(id);
    }

    function getDueTime(bytes32 id) external view returns (uint256) {
        Config storage config = configs[id];
        uint256 last = states[id].lastPayment;
        uint256 duration = config.duration;
        last = last != 0 ? last : duration;
        return last - (last % duration) + config.lentTime;
    }

    function getFinalTime(bytes32 id) external view returns (uint256) {
        Config storage config = configs[id];
        return config.lentTime + (uint256(config.duration) * (uint256(config.installments)));
    }

    function getFrequency(bytes32 id) external view returns (uint256) {
        return configs[id].duration;
    }

    function getInstallments(bytes32 id) external view returns (uint256) {
        return configs[id].installments;
    }

    function getEstimateObligation(bytes32 id) external view returns (uint256) {
        return _getClosingObligation(id);
    }

    function simFirstObligation(bytes _data) external view returns (uint256 amount, uint256 time) {
        (amount,,, time) = _decodeData(_data);
    }

    function simTotalObligation(bytes _data) external view returns (uint256 amount) {
        (uint256 cuota,, uint256 installments,) = _decodeData(_data);
        amount = cuota * installments;
    }

    function simDuration(bytes _data) external view returns (uint256 duration) {
        (,, uint256 installments, uint256 installmentDuration) = _decodeData(_data);
        duration = installmentDuration * installments;
    }

    function simPunitiveInterestRate(bytes _data) external view returns (uint256 punitiveInterestRate) {
        (,punitiveInterestRate,,) = _decodeData(_data);
    }

    function simFrequency(bytes _data) external view returns (uint256 frequency) {
        (,,, frequency) = _decodeData(_data);
    }

    function simInstallments(bytes _data) external view returns (uint256 installments) {
        (,, installments,) = _decodeData(_data);
    }

    function _advanceClock(bytes32 id, uint256 _target) internal returns (bool) {
        Config storage config = configs[id];
        State storage state = states[id];

        uint256 clock = state.clock;
        if (clock < _target) {
            (uint256 newInterest, uint256 newClock) = _runAdvanceClock({
                _clock: state.clock,
                _interest: state.interest,
                _duration: config.duration,
                _cuota: config.cuota,
                _installments: config.installments,
                _paidBase: state.paidBase,
                _interestRate: config.interestRate,
                _targetClock: _target
            });

            require(newClock < U_64_OVERFLOW, "Clock overflow");
            require(newInterest < U_128_OVERFLOW, "Interest overflow");

            emit _setClock(id, uint64(newClock));

            if (newInterest != 0) {
                emit _setInterest(id, uint128(newInterest));
            }

            state.clock = uint64(newClock);
            state.interest = uint128(newInterest);

            return true;
        }
    }

    function _getClosingObligation(bytes32 id) internal view returns (uint256) {
        State storage state = states[id];
        Config storage config = configs[id];

        // Static storage loads
        uint256 installments = config.installments;
        uint256 cuota = config.cuota;
        uint256 currentClock = uint64(now) - config.lentTime;

        uint256 interest;
        uint256 clock = state.clock;

        if (clock >= currentClock) {
            interest = state.interest;
        } else {
            (interest,) = _runAdvanceClock({
                _clock: clock,
                _interest: state.interest,
                _duration: config.duration,
                _cuota: cuota,
                _installments: installments,
                _paidBase: state.paidBase,
                _interestRate: config.interestRate,
                _targetClock: currentClock
            });
        }

        uint256 debt = cuota * installments + interest;
        uint256 paid = state.paid;
        return debt > paid ? debt - paid : 0;
    }


    function _runAdvanceClock(
        uint256 _clock,
        uint256 _interest,
        uint256 _duration,
        uint256 _cuota,
        uint256 _installments,
        uint256 _paidBase,
        uint256 _interestRate,
        uint256 _targetClock
    ) internal pure returns (uint256 interest, uint256 clock) {
        // Advance clock to lentTime if never advanced before
        clock = _clock;
        interest = _interest;

        // Aux variables
        uint256 delta;
        bool installmentCompleted;
        
        do {
            // Delta to next installment and absolute delta (no exceeding 1 installment)
            (delta, installmentCompleted) = _calcDelta({
                _targetDelta: _targetClock - clock,
                _clock: clock,
                _duration: _duration,
                _installments: _installments
            });

            // Running debt
            uint256 newInterest = _newInterest({
                _clock: clock,
                _duration: _duration,
                _installments: _installments,
                _cuota: _cuota,
                _paidBase: _paidBase,
                _delta: delta,
                _interestRate: _interestRate
            });

            // Don't change clock unless we have a change
            if (installmentCompleted || newInterest > 0) {
                clock += delta;
                interest += newInterest;
            } else {
                break;
            }
        } while (clock < _targetClock);
    }

    function _calcDelta(
        uint256 _targetDelta,
        uint256 _clock,
        uint256 _duration,
        uint256 _installments
    ) internal pure returns (uint256 delta, bool installmentCompleted) {
        uint256 nextInstallmentDelta = _duration - _clock % _duration;
        if (nextInstallmentDelta <= _targetDelta && _clock / _duration < _installments) {
            delta = nextInstallmentDelta;
            installmentCompleted = true;
        } else {
            delta = _targetDelta;
            installmentCompleted = false;
        }
    }

    function _newInterest(
        uint256 _clock,
        uint256 _duration,
        uint256 _installments,
        uint256 _cuota,
        uint256 _paidBase,
        uint256 _delta,
        uint256 _interestRate
    ) internal pure returns (uint256) {
        uint256 runningDebt = _baseDebt(_clock, _duration, _installments, _cuota) - _paidBase;
        uint256 newInterest = (100000 * _delta * runningDebt) / _interestRate;
        require(newInterest < U_128_OVERFLOW, "New interest overflow");
        return newInterest;
    }

    function _baseDebt(
        uint256 clock,
        uint256 duration,
        uint256 installments,
        uint256 cuota
    ) internal pure returns (uint256 base) {
        uint256 installment = clock / duration;
        return uint128(installment < installments ? installment * cuota : installments * cuota);
    }

    function _validate(
        uint256 _cuota,
        uint256 _interestRate,
        uint256 _installments,
        uint256 _installmentDuration
    ) internal pure {
        require(_cuota > 0, "Cuota can't be 0");
        require(_interestRate > 0, "Interest rate can't be 0");
        require(_installments > 0, "Installments can't be 0");
        require(_installmentDuration > 0, "Installment duration can't be 0");
    }

    function _decodeData(
        bytes _data
    ) internal pure returns (uint128, uint256, uint24, uint40) {
        require(_data.length == L_DATA, "Invalid data length");
        (bytes32 cuota, bytes32 interestRate, bytes32 installments, bytes32 duration) = decode(_data, 16, 32, 3, 5);
        return (uint128(cuota), uint256(interestRate), uint24(installments), uint40(duration));
    }
}