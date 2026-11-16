# Cámara Downloader

App de Windows para descargar rápido todos los archivos de una **GoPro**, una **Insta360** o **cualquier carpeta** a un disco de la PC, organizados en carpetas por fecha de grabación (`AAAA-MM-DD`).

## Instalar

1. Bajá `CamaraDownloader-Setup.exe` de la [última versión](https://github.com/ChrisAlf27/CamaraDownloader/releases/latest).
2. Ejecutalo. Como el instalador no está firmado, Windows puede mostrar *"Windows protegió su PC"*: tocá **Más información → Ejecutar de todas formas**.
3. Queda un acceso directo **Cámara Downloader** en el escritorio y en el menú Inicio. No hace falta ser administrador.

**Actualizaciones:** al abrir, la app se fija si hay una versión nueva. Si la hay, la ofrece, la instala sola y se vuelve a abrir.

## Uso

1. Conectá la cámara:
   - **GoPro:** por USB, encendida, con la conexión USB en modo **MTP** (*Preferencias → Conexiones → Conexión USB*), o la tarjeta SD en un lector.
   - **Insta360:** por USB en modo **U-Disk** (almacenamiento USB), o la tarjeta SD en un lector.
2. Abrí la app. Si detecta una cámara, la elige sola; si no, elegí **GoPro**, **Insta360** u **Otra carpeta**. Con *Otra carpeta* elegís el origen a mano.
3. Revisá **Guardar en** (cada opción recuerda su propia carpeta) y tocá **Descargar todo**.

## Qué hace

- Detecta la cámara por USB (MTP) o como unidad / tarjeta SD. El lector de tarjetas es 2 a 3 veces más rápido.
- Copia solo lo nuevo y verifica el tamaño de cada archivo. Si dos archivos distintos tienen el mismo nombre, no pisa ninguno: guarda el segundo como `nombre (2).ext`.
- Toma la fecha del nombre del archivo cuando la tiene (Insta360: `VID_20261116_101500_...`) y si no, de la fecha del archivo.
- Muestra progreso, velocidad y tiempo restante. La copia corre en un hilo aparte, así que la ventana no se congela.
- Al terminar sin errores, pregunta si querés borrar del origen lo copiado (incluye los LRV/THM de esos videos).
- Por defecto no copia los LRV/THM (proxies y miniaturas); hay una casilla para incluirlos.
- Los `.insv`/`.insp` de Insta360 se copian tal cual. Para unirlos y editarlos hace falta Insta360 Studio.

## Desarrollo

| Archivo | Qué es |
|---|---|
| `src/CamaraDownloader.ps1` | La app (PowerShell 5.1 + WinForms). Tiene que estar en UTF-8 **con BOM**. |
| `src/Launcher.cs` | `CamaraDownloader.exe`: abre el script sin ventana de consola. |
| `installer/CamaraDownloader.iss` | Instalador (Inno Setup 6). Instala en `%LOCALAPPDATA%\Programs\CamaraDownloader`. |
| `assets/make-icon.ps1` | Genera `assets/app.ico`. |
| `build.ps1` | Compila el lanzador y el instalador en `dist/`. |
| `Camara Downloader.bat` | Abre la app desde el código, sin instalar (no se auto-actualiza). |

Requisitos para compilar: `winget install JRSoftware.InnoSetup GitHub.cli` y `gh auth login`.

### Publicar una versión nueva

1. Subí `$AppVersion` en `src/CamaraDownloader.ps1` (por ejemplo `2.0.0` → `2.1.0`).
2. Hacé commit y push.
3. Ejecutá `.\build.ps1 -Publish -Notes "Qué cambió"`. Crea el Release `v2.1.0` en GitHub con el instalador, y las apps instaladas lo ofrecen la próxima vez que se abren.

### Notas técnicas

- Por MTP, Windows puede devolver los nombres sin extensión y fechas vacías (1899-12-30). La app toma el nombre real con `System.FileName` y busca la fecha en varias propiedades y en las columnas de fecha del Explorador.
- Las copias se hacen a un archivo temporal (`.part`, o la carpeta oculta `_copiando` para MTP) y se renombran al terminar: en el destino nunca queda un archivo a medias.
- La configuración se guarda en `%APPDATA%\CamaraDownloader\settings.json`.
