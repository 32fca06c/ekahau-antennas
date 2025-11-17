## Установка Powershell на Linux и macOS
https://learn.microsoft.com/ru-ru/powershell/scripting/install/installing-powershell

## Запуск сторонних скриптов на Windows  
Запустить Powershell с правами администратора и выполнить следующую команду:  
```
Set-ExecutionPolicy unrestricted
```

## Запуск обновления и инъекции
Загрузить репозиторий по ссылке  
```
https://github.com/32fca06c/ekahau-antennas/archive/refs/heads/main.zip
```
выполнить скрипт `build.ps1` от имени непривилегированного пользователя  

Рекомендуется отключение автоматического обновления паттернов антенн и точек доступа в меню: `File` -> `Preferences...` -> `Automatic antenna and AP updates`  

## Моё почтение

Замку G 2007 года рождения  
Хлебобулочному изделию  
Екарному Бабаю  
Лучшей версии Java  

## Нюанс форматирования
.json должен быть LF (для MacOS и Linux) и CRLF (для Windows)  
.xml должен быть CRLF  
