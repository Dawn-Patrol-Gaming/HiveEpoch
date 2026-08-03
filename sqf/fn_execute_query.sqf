if (Debug_DBFunctions) then {diag_log format["Executing: %1",__FILE__];};
private ["_params","_dbcall","_msg","_return","_result","_function","_tmp","_data","_count"];
_params = _this;
//init just in case
_dbcall = "";
_msg = "";
_return = true;
_result = "";
_msg = "";

_function = _params select 0;
_dbcall = _function;

{
	if (_foreachIndex > 0) then {
		_tmp = format[":%1",_params select _forEachIndex];
		if (Debug_DBFunctions) then {diag_log format["_tmp: %1",_tmp];};
		_dbcall = _dbcall + format[_tmp,_params select _forEachIndex];
		if (Debug_DBFunctions) then {diag_log format["_dbcall: %1",_dbcall];};
	};
} foreach _params;
//_dbcall = format[_dbcall,_params];
if (Debug_DBFunctions) then {diag_log format["_dbcall: %1",_dbcall];};

_data = "dzfunctions" callExtension _dbcall;
if (Debug_DBFunctions) then {diag_log format["_data %1",_data];};

_msg = call compile _data;
if (Debug_DBFunctions) then {diag_log format["_msg %1",_msg];};
//result should look like [<bool>,[<count>]]

_return = _msg select 0;
if (Debug_DBFunctions) then {diag_log format["_return %1",_return];};

_count = (_msg select 1) select 0;
if (Debug_DBFunctions) then {diag_log format["_count %1",_count];};

if (typeName _count == "STRING") then {_return = false;};//should always return a number unless it sent a string, which then it failed
//_result = _return && (_count > 0);//don't think we're going to eval this yet, probably shouldn't for this function since we're going 
									//to call it with stuff that may or may not have an affected count
_result = _return;
if (Debug_DBFunctions) then {diag_log format["_result %1",_result];};

if !(_result) then {
	diag_log format["Execute function: %1 failed, message: %2",_function,_count];
};
[_result,_count]