if (Debug_DBFunctions) then {diag_log format["Executing: %1",__FILE__];};
private ["_params","_dbcall","_msg","_return","_result","_function","_tmp","_data","_mgs","_count"];
if (Debug_DBFunctions) then {diag_log format["_this: %1",_this];};
_params = _this;
//init just in case
_dbcall = "";
_msg = "";
_return = true;
_result = "";
_msg = "";

_function = _params select 0;
if (Debug_DBFunctions) then {diag_log format["_function: %1",_function];};
_dbcall = _function;

{
	_tmp = _x;
	if (_foreachIndex > 0) then {
		//always assume the first parameter is an ID of some type
		//this fixes numbers formatted as strings so i don't have to do it in the dll
		//this was brought about by the stupidly large inventories being saved to the database
		if (_foreachIndex == 1) then { 
			_tmp = format["%1",_x]; 
			if (Debug_DBFunctions) then {diag_log format["_foreachIndex == 1: %1",_tmp];};
		};
		if (Debug_DBFunctions) then {diag_log format["_tmp: %1",_tmp];};
		if (typeName _tmp != "SCALAR") then {
			_dbcall = _dbcall + ":" + (str _tmp);
		} else {
			_dbcall = _dbcall + ":" + format["%1",_tmp];
		};
		if (Debug_DBFunctions) then {diag_log format["_dbcall: %1",_dbcall];};
	};
} foreach _params;
//_dbcall = format[_dbcall,_params];
if (Debug_DBFunctions) then {diag_log format["_dbcall: %1",_dbcall];};

_data = "dzfunctions" callExtension _dbcall;
if (Debug_DBFunctions) then {diag_log format["_data %1",_data];};

_mgs = call compile _data;
if (Debug_DBFunctions) then {diag_log format["_mgs %1",_mgs];};
//result should look like [<bool>,[<count>]]

_return = _mgs select 0;
if (Debug_DBFunctions) then {diag_log format["_return %1",_return];};

_count = (_mgs select 1) select 0;
if (Debug_DBFunctions) then {diag_log format["_count %1",_count];};

//should always return a number unless it sent a string, which then it failed
if (typeName _count == "STRING") then {
	_return = false;
	diag_log format["ERROR : %1",_count];
} else {
	_result = _return && (_count > 0);	
};

if (Debug_DBFunctions) then {diag_log format["_result %1",_result];};

if !(_result) then {
	diag_log format["Update function: %1 failed, message: %2 _this: %3",_function,_count,_this];
};
if (isNil "_result") then {_result = false;};
_result
