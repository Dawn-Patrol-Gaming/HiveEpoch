In order to use these on the server, define a global var called Debug\_DBFunctions and set it to true or false.

You can cause the dll to output debug messages by calling this at server startup (or at any point) from sqf:

```
_dbcall = format["initialize:%1",Debug_DBFunctions];
_data = "dzfunctions" callExtension _dbcall;
```

##### These are some samples of how to execute cleanups of the database at server startup:

```
//clean up database after every restart instead of relying on mysql event scheduler
_tz = ['getTimezone'] call fn_get_data;
diag_log format["Timezone and date/time returned from SQL server: %1",_tz];
```

```
_data = ["cleanLockedSafes"] call fn_execute_query;
_count = _data select 1;
diag_log format["Locked safe cleanup unlocked: %1",_count];

_data = ["cleanLockedLockboxes"] call fn_execute_query;
_count = _data select 1;
diag_log format["Locked lockbox cleanup unlocked: %1",_count];

_data = ["cleanObjects"] call fn_execute_query;
_count = _data select 1;
diag_log format["Object cleanup deleted objects: %1",_count];
```

##### In this folder are the sqf that you can call that centralizes the types of queries you would run, examples:

Deleting data:

```
if (_objectID > 0) then {
    _return = ["deleteObject",_objectID] call fn_delete_data;
    _result = _return select 0;
} else {
    _result = true;
    _return = ["No DB Record",_objectID];
};
```

Straight up executing a query:

```
_data = ["cleanObjects"] call fn_execute_query;
_count = _data select 1;
diag_log format["Object cleanup deleted objects: %1",_count];
```

Retrieving data:

```
if ((typename _inventory) != "ARRAY") then {
    _data = ["getObjectInventory",_objectID] call fn_get_data;
    _inventory = (_data select 1) select 0;    
    _object setVariable["_inventory",_inventory];
};
```

Inserting data:

```
_dbresult = ["insertObject",dayZ_instance,typeOf _object,_characterID,_worldspace,_inventory] call fn_insert_data;
if (Debug_Object_Insert) then {diag_log format["_dbresult: %1",_dbresult];};
```

Updating data:

```
_return = ["updateObjectCoins",_objectID,_coins] call fn_update_data;
if !(_return) exitwith {diag_log format["ERROR updating database (coins field) in: %1 - _this: %2",__FILE__,_this];};
```

Specialized functionality, bulk maintain plot pole, this happens 1000x faster than native epoch, only a couple seconds instead of waiting for each object to get updated:

```
pushbackUnique = {
	private ["_theList","_theItem"];
	_theList = _this select 0;
	_theItem = _this select 1;
	if (isNil "_theItem") exitwith {diag_log "ERROR IN PUSHBACKUNIQUE no item passed";};
	if (isNil "_theList") then {_theList = [];};
	if (typename _theList == "ARRAY") then {
		if !(_theItem in _theList) then {
			_thelist set [count _thelist,_theItem];
		};
	};
	_theList
};

_objects = nearestObjects [_plot, BuildingClasses, DZE_maintainRange];
{
	_obj = _x;
	_objectID = _obj getVariable ["ObjectID","-1"];
	if (!(isNil "_objectID") && ((damage _obj) < 1)) then {
		if ((typeName _objectID) == "STRING") then {_objectID = parseNumber _objectID;};
		//build array of objects and objectid for setting damage and saving later
		[_objectsInfo, [_obj, _objectID],__FILE__] call pushbackunique;
		//build array to use for updating database
		[_tmpObjIDs,_objectID,__FILE__] call pushbackunique;
		//we're doing this in batches of 100, add an array of 100 objects to the list when _tmpObjIDs count >= 100
		if (_objectID > 0) then {
			if (count _tmpObjIDs >= 100) then {
				[_objectidList,_tmpObjIDs,__FILE__] call pushbackunique;
				_tmpObjIDs = [];//reset for next batch
			};
		};
	};
} foreach _objects;

```

Writing to a custom log file:

```
[player,"thelogfilename","this is a log message"] call fn_server_write_remote_log;
```