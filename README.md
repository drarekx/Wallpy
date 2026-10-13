# Wallpy

Fondos de pantalla con vídeo para macOS. Vive en la barra de menú, pone un vídeo en bucle detrás de tus ventanas y se pausa solo cuando no lo ves.

## Instalar

Abre Terminal y pega:

```sh
curl -fsSL https://raw.githubusercontent.com/drarekx/Wallpy/main/install.sh | bash
```

El instalador descarga la última versión, la copia en `/Applications`, la abre y, si tienes [Homebrew](https://brew.sh), instala `yt-dlp` y `ffmpeg` (necesarios para descargar de YouTube y para el editor de bucles). Para no instalarlos:

```sh
curl -fsSL https://raw.githubusercontent.com/drarekx/Wallpy/main/install.sh | bash -s -- --no-deps
```

Wallpy se actualiza sola: busca versiones nuevas al arrancar y una vez al día (o desde el menú → **Buscar actualizaciones…**), comprueba la descarga con su SHA-256 y se reinicia ya actualizada. Se puede desactivar en Ajustes. Volver a ejecutar el comando de instalación también actualiza.

**Instalación manual:** descarga `Wallpy.zip` de [Releases](https://github.com/drarekx/Wallpy/releases/latest), descomprímelo y mueve `Wallpy.app` a Aplicaciones. La app no está notarizada por Apple, así que la primera vez ábrela con clic derecho → **Abrir** (o Ajustes del Sistema → Privacidad y seguridad → **Abrir igualmente**).

Requisitos: macOS 14 (Sonoma) o posterior. Apple Silicon o Intel.

## Qué hace

- **Fondos de vídeo** en todas tus pantallas, un vídeo distinto por pantalla si quieres, y en todos los Spaces.
- **Biblioteca**: arrastra vídeos (MP4, MOV, M4V) o imágenes (JPG, PNG, HEIC, WebP, TIFF), o súbelos con el botón. Los GIF y PNG animados se convierten solos en vídeo en bucle (necesita `ffmpeg`).
- **Descarga de YouTube** con elección de calidad (1080p, 1440p, 4K).
- **Editor de bucles** estilo editor de vídeo: monitor grande, línea de tiempo con miniaturas y zoom, marcas de entrada/salida, varios tramos por vídeo y exportación en cola.
  - Fundido del bucle para que no se note el salto al repetir.
  - Optimización: HEVC por hardware, resolución, calidad, 30 fps, quitar sonido.
- **Originales**: guarda vídeos largos para sacar más fondos otro día sin volver a descargarlos.
- **Ahorro de energía**: pausa cuando las ventanas tapan el escritorio, con batería o con batería baja, y cuando se apagan las pantallas.
- Ocultar iconos del escritorio, volumen (silenciado por defecto) y abrir al iniciar sesión.
- **Idiomas**: castellano, inglés y catalán (Ajustes → Idioma; por defecto, el del sistema).

### Atajos del editor

| Tecla | Acción |
|---|---|
| Espacio | Reproducir / pausa |
| I / O | Marcar entrada / salida |
| N | Nuevo tramo en el cabezal |
| ← / → | Fotograma anterior / siguiente |
| ⇧← / ⇧→ | 1 segundo atrás / adelante |
| ↑ / ↓ | Ir a la entrada / salida |
| L | Repetir solo el tramo |
| J / K | 5 s atrás / pausa |
| + / − | Zoom de la línea de tiempo |
| ⌥ + arrastrar | Mover el tramo entero |

> Descarga solo vídeos tuyos, con licencia libre o con permiso de su autor. Descargar contenido de YouTube puede ir contra sus condiciones de uso.

## Dónde guarda las cosas

- Fondos y originales: `~/Library/Application Support/Wallpy/`
- Ajustes: `defaults read com.egluu.wallpy`

## Desinstalar

```sh
osascript -e 'quit app "Wallpy"'
rm -rf /Applications/Wallpy.app ~/Library/Application\ Support/Wallpy
defaults delete com.egluu.wallpy
```

## Compilar desde el código

Necesitas Xcode 16 o posterior.

```sh
git clone https://github.com/drarekx/Wallpy.git
cd Wallpy
./build-app.sh          # deja build/Wallpy.app y build/Wallpy.zip
open build/Wallpy.app
```

Para publicar una versión nueva, crea y sube una etiqueta; GitHub Actions compila la app y crea el release con el zip:

```sh
git tag v1.0.1 && git push origin v1.0.1
```
