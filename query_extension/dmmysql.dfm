object DataModuleMySQL: TDataModuleMySQL
  OnDestroy = DataModuleDestroy
  Height = 265
  Width = 342
  object mySQLQuery: TUniQuery
    Connection = mySQLDatabase
    Left = 80
    Top = 80
  end
  object mySQLQueryObjects: TUniQuery
    Connection = mySQLDatabase
    SQL.Strings = (
      
        'SELECT o.ObjectID, o.Classname, o.CharacterID, o.Worldspace, o.I' +
        'nventory,'
      
        'o.Hitpoints, o.Fuel, o.Damage, o.StorageCoins, a.objectname, a.o' +
        'wneruid,'
      
        'case when a.accesslist IS null then '#39'[]'#39' ELSE a.accesslist END A' +
        'S accesslist,'
      '1 as theorder'
      'from object_data o LEFT OUTER JOIN object_access_lists a'
      'ON o.objectid = a.objectid'
      'where classname in (select classname from building_classes)'
      'and damage < 1'
      'union'
      
        'SELECT o.ObjectID, o.Classname, o.CharacterID, o.Worldspace, o.I' +
        'nventory,'
      
        'o.Hitpoints, o.Fuel, o.Damage, o.StorageCoins, a.objectname, a.o' +
        'wneruid,'
      
        'case when a.accesslist IS null then '#39'[]'#39' ELSE a.accesslist END A' +
        'S accesslist,'
      '2 as theorder'
      'from object_data o LEFT OUTER JOIN object_access_lists a'
      'ON o.objectid = a.objectid'
      'where classname not in (select classname from building_classes)'
      'and damage < 1'
      'order by theorder')
    FetchRows = 20000
    UniDirectional = True
    Options.EnableBCD = True
    Left = 80
    Top = 144
  end
  object MySQLProvider: TMySQLUniProvider
    Left = 184
    Top = 80
  end
  object mySQLDatabase: TUniConnection
    LoginPrompt = False
    Left = 80
    Top = 24
  end
end
