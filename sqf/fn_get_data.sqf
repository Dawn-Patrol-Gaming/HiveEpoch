if (Debug_DBFunctions) then {diag_log format["Executing: %1",__FILE__];};
private ["_params","_dbcall","_msg","_return","_result","_function","_tmp","_data"];
_params = _this;
//init just in case
_dbcall = "";
_msg = "";
_return = true;
_result = "";

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
if (Debug_DBFunctions) then {diag_log format["_msg %1 typename _msg: %2",_msg,typename _msg];};
//result should look like [<bool>,[<count>]]

_return = _msg select 0;
if (Debug_DBFunctions) then {diag_log format["_return %1 typename _return: %2",_return,typename _return];};

_result = _msg select 1;
if (Debug_DBFunctions) then {diag_log format["_result %1 typename _result: %2",_result,typename _result];};

//i don't really want to do this based on query name, but so i don't get spammed in the rpt for no reason
//getObjectIDFromUID gets called repeatedly because of how epoch inserts and doesn't bother with objectid
//after, so we do this instead of replacing all insert database calls from epoch
if (!(_return) && (_dbcall !="getObjectIDFromUID")) then {
	diag_log format["Retrieval function: %1 failed, message: %2",_function,_msg];
};
[_return,_result]