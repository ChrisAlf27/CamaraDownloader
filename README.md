# GoPro Downloader

App de Windows para descargar rápido todos los archivos de una GoPro conectada por USB (o de su tarjeta SD) a un disco de la PC, organizados en carpetas por fecha de grabación.

## Uso

1. Conectá la GoPro por USB, encendela y poné la conexión USB en modo **MTP** (*Preferencias → Conexiones → Conexión USB*).
2. Doble clic en **`Descargar GoPro.bat`**.
3. Tocá **Descargar todo**. Por defecto los archivos van a `G:\GoPro\AAAA-MM-DD\` (se puede cambiar con el botón *Cambiar...*).

## Qué hace

- Detecta la GoPro por USB (MTP) o una tarjeta SD en un lector, que es 2 a 3 veces más rápido.
- Copia solo lo nuevo y verifica el tamaño de cada archivo.
- Si encuentra copias ya hechas en otra carpeta del destino, las mueve a la carpeta de su fecha en vez de copiarlas otra vez.
- Muestra progreso, velocidad y tiempo restante. La copia corre en un hilo aparte, así que la ventana no se congela.
- Al terminar sin errores, pregunta si querés borrar de la cámara lo copiado (incluye los LRV/THM de esos videos).
- Por defecto no copia los archivos LRV/THM (proxies y miniaturas); hay una casilla para incluirlos.

## Requisitos

Windows 10/11 con Windows PowerShell 5.1 (viene instalado). No necesita instalar nada.

## Notas técnicas

- `GoProDownloader.ps1` tiene que estar guardado en UTF-8 **con BOM** y saltos de línea CRLF (`.gitattributes` se encarga de los saltos de línea).
- Por MTP, Windows puede devolver los nombres sin extensión y fechas vacías (1899-12-30). La app toma el nombre real con `System.FileName` y busca la fecha en varias propiedades y en las columnas de fecha del Explorador.
