import Combine
import Foundation

/// Languages the UI is translated to. Spanish strings are the keys.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, es, ca
    var id: String { rawValue }

    /// Shown in its own language, so anyone can find theirs.
    var nativeName: String {
        switch self {
        case .system: return tr("Sistema")
        case .en: return "English"
        case .es: return "Español"
        case .ca: return "Català"
        }
    }
}

final class Localizer: ObservableObject {
    static let shared = Localizer()

    @Published var choice: AppLanguage {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: "appLanguage") }
    }

    private init() {
        choice = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "") ?? .system
    }

    /// The language actually used: the chosen one, or the first supported system language (English otherwise).
    var language: AppLanguage {
        if choice != .system { return choice }
        for preferred in Locale.preferredLanguages {
            let code = String(preferred.prefix(2))
            if let match = AppLanguage(rawValue: code), match != .system { return match }
        }
        return .en
    }

    var locale: Locale { Locale(identifier: language.rawValue) }

    func translate(_ key: String) -> String {
        switch language {
        case .en: return Translations.en[key] ?? key
        case .ca: return Translations.ca[key] ?? key
        default: return key
        }
    }
}

/// Translated UI text. `key` is the Spanish text.
func tr(_ key: String) -> String {
    Localizer.shared.translate(key)
}

/// Translated format string (`%@`, `%d`) with arguments.
func tr(_ key: String, _ args: CVarArg...) -> String {
    String(format: Localizer.shared.translate(key), locale: Localizer.shared.locale, arguments: args)
}

private enum Translations {
    static let en: [String: String] = [
        // Menus
        "Cerrar ventana": "Close Window",
        "Salir de Wallpy": "Quit Wallpy",
        "Edición": "Edit",
        "Deshacer": "Undo",
        "Rehacer": "Redo",
        "Cortar": "Cut",
        "Copiar": "Copy",
        "Pegar": "Paste",
        "Seleccionar todo": "Select All",
        "Abrir biblioteca…": "Open Library…",
        "Pausar fondos": "Pause Wallpapers",
        "Silenciar": "Mute",
        "Ocultar iconos del escritorio": "Hide Desktop Icons",
        "Abrir al iniciar sesión": "Open at Login",
        "Actualizando…": "Updating…",
        "Buscar actualizaciones…": "Check for Updates…",
        "Invítame a un café…": "Buy Me a Coffee…",

        // Library window
        "Sistema": "System",
        "Idioma": "Language",
        "Biblioteca": "Library",
        "Originales": "Originals",
        "Ajustes": "Settings",
        "Pantallas": "Displays",
        "Sin fondo": "No wallpaper",
        "En pausa": "Paused",
        "Reproduciendo": "Playing",
        "Se pausa cuando las ventanas tapan el escritorio.": "Pauses when windows cover the desktop.",
        "Se reproduce siempre.": "Always plays.",
        "Reanudar fondos": "Resume Wallpapers",
        "Versión %@": "Version %@",
        "Arrastra vídeos o imágenes aquí": "Drag videos or images here",
        "No se pudieron añadir algunos archivos": "Some files couldn't be added",
        "OK": "OK",
        "Este fondo está en uso. ¿Seguro que quieres eliminarlo?": "This wallpaper is in use. Are you sure you want to delete it?",
        "Eliminar": "Delete",
        "Importando…": "Importing…",
        "Todo": "All",
        "Vídeos": "Videos",
        "Imágenes": "Images",
        "Buscar": "Search",
        "Desde YouTube…": "From YouTube…",
        "Añadir…": "Add…",
        "Añadir": "Add",
        "Vídeos: MP4, MOV, M4V. Imágenes: JPG, PNG, HEIC, WebP, TIFF. Los GIF se convierten en vídeo.":
            "Videos: MP4, MOV, M4V. Images: JPG, PNG, HEIC, WebP, TIFF. GIFs are converted to video.",
        "Poner en todas las pantallas": "Set on All Displays",
        "Poner en %@": "Set on %@",
        "Recortar y optimizar…": "Trim and Optimize…",
        "Mostrar en Finder": "Show in Finder",
        "En uso": "In use",
        "Imagen": "Image",
        "Resolución baja": "Low resolution",
        "Nombre": "Name",
        "Tipo": "Type",
        "Vídeo": "Video",
        "Resolución": "Resolution",
        "Duración": "Duration",
        "Tamaño": "Size",
        "En pantalla": "On Display",
        "Eliminar de la biblioteca": "Delete from Library",
        "Vídeos completos guardados para sacar más fondos sin volver a descargarlos.":
            "Full videos kept to make more wallpapers without downloading them again.",
        "Espacio usado": "Space Used",
        "Aún no hay originales": "No originals yet",
        "Al descargar de YouTube, activa «Guardar en Originales» en el editor para conservar el vídeo completo.":
            "When downloading from YouTube, turn on “Save to Originals” in the editor to keep the full video.",
        "¿Eliminar «%@»? Los fondos ya creados a partir de él no se borran.":
            "Delete “%@”? Wallpapers already made from it are kept.",
        "Guardado el %@": "Saved %@",
        "Crear fondos": "Create Wallpapers",
        "Eliminar original": "Delete Original",
        "Ninguno": "None",
        "Ahorro de energía": "Energy Saving",
        "Pausar cuando las ventanas tapan el escritorio": "Pause when windows cover the desktop",
        "Recomendado: no gasta nada si no lo ves": "Recommended: uses nothing when you can't see it",
        "Pausar con batería baja": "Pause on low battery",
        "Por debajo de %d %%": "Below %d %%",
        "Batería: %d %% · %@": "Battery: %d %% · %@",
        "con batería": "on battery",
        "conectado": "plugged in",
        "Sonido y escritorio": "Sound and Desktop",
        "Volumen": "Volume",
        "Actualizaciones": "Updates",
        "Buscar actualizaciones automáticamente": "Check for updates automatically",
        "Versión ": "Version ",
        "Buscar ahora": "Check Now",
        "Herramientas": "Tools",
        "Instalado": "Installed",
        "No instalado": "Not installed",
        "Necesarios para descargar de YouTube, el editor de bucles y convertir GIF.":
            "Needed for YouTube downloads, the loop editor and GIF conversion.",
        "Instálalos con: brew install yt-dlp ffmpeg": "Install them with: brew install yt-dlp ffmpeg",

        "Sin cargador": "When unplugged",
        "Seguir": "Keep playing",
        "Pausar": "Pause",
        "Imagen fija": "Still image",
        "Añade una imagen a la biblioteca para usarla aquí.": "Add an image to the library to use it here.",
        "Elige una imagen": "Choose an image",
        "Mientras no esté enchufado, las pantallas con vídeo muestran esta imagen y el vídeo deja de gastar.":
            "While unplugged, screens with a video show this image and the video stops using power.",
        "Aplicar también en modo de bajo consumo": "Also in Low Power Mode",
        "El modo de bajo consumo está activado": "Low Power Mode is on",
        "Sin fondos de vídeo": "No video wallpapers",
        "Pausado desde el menú.": "Paused from the menu.",
        "Sin cargador: los vídeos vuelven al enchufarlo.": "Unplugged: videos resume when you plug in.",
        "Sin cargador: se muestra la imagen elegida.": "Unplugged: showing the chosen image.",
        "Batería baja.": "Low battery.",
        "El Mac está muy caliente; se reanuda al enfriarse.": "The Mac is very hot; resumes when it cools down.",
        "Madrugada": "Dawn",
        "Mañana": "Morning",
        "Tarde": "Afternoon",
        "Noche": "Night",
        "Siempre": "Always",
        "Momentos del día": "Times of Day",
        "desde": "from",
        "Programación": "Schedule",
        "No está programado en ningún momento.": "Not scheduled for any time of day.",
        "Abrir programación": "Open Schedule",
        "Elige qué fondo se ve en cada pantalla y en cada momento del día.": "Choose what each display shows at each time of day.",
        "Cambiar según el momento del día": "Change with the time of day",
        "Activa «Cambiar según el momento del día» para que se apliquen las columnas de los momentos. Mientras tanto se usa «Siempre».":
            "Turn on “Change with the time of day” to use the time-of-day columns. Until then, “Always” is used.",
        "Pantalla": "Display",
        "Ahora": "Now",
        "Fondo base": "Base wallpaper",
        "Usa Siempre": "Uses Always",
        "Pincha una casilla para elegir el fondo. «Siempre» es el fondo base de cada pantalla: se ve en los momentos que no tengan uno propio.":
            "Click a cell to choose its wallpaper. “Always” is each display's base wallpaper: it shows at any time of day without its own.",
        "%@ · %@": "%@ · %@",
        "Aplicar a todas las pantallas": "Apply to all displays",
        "Añade fondos en la Biblioteca para programarlos.": "Add wallpapers in the Library to schedule them.",
        "Quitar el fondo": "Remove wallpaper",
        "Usar el de Siempre": "Use Always",
        // Loop editor
        "Editor de bucle — %@": "Loop Editor — %@",
        "Editor de bucle": "Loop Editor",
        "DENTRO DEL BUCLE": "INSIDE LOOP",
        "Ir a la entrada (↑)": "Go to In (↑)",
        "Fotograma anterior (←)": "Previous Frame (←)",
        "Reproducir / pausa (Espacio)": "Play / Pause (Space)",
        "Fotograma siguiente (→)": "Next Frame (→)",
        "Ir a la salida (↓)": "Go to Out (↓)",
        "Entrada": "In",
        "Marcar entrada (I)": "Mark In (I)",
        "Salida": "Out",
        "Marcar salida (O)": "Mark Out (O)",
        "Repetir tramo": "Loop Clip",
        "Reproducir solo entre entrada y salida (L)": "Play only between In and Out (L)",
        "Duración del bucle": "Loop Duration",
        "Ajustar al tramo": "Fit to Clip",
        "Ver todo": "Show All",
        "Arrastra para buscar · bordes azules: entrada/salida · ⌥ arrastrar: mover tramo · clic en la franja de tramos: seleccionar · N nuevo tramo · I / O marcan · Espacio reproduce · ← → fotograma · ⇧← ⇧→ 1 s · + / − zoom":
            "Drag to scrub · blue edges: in/out · ⌥ drag: move clip · click the clip strip: select · N new clip · I / O mark · Space plays · ← → frame · ⇧← ⇧→ 1 s · + / − zoom",
        "Mapa del vídeo completo: arrastra para moverte por la línea de tiempo": "Full video map: drag to move along the timeline",
        "Nuevo tramo en el cabezal (N)": "New Clip at Playhead (N)",
        "Tramos (%d)": "Clips (%d)",
        "Haz tantos fondos como quieras del mismo vídeo. Cada tramo se exporta como un fondo independiente.":
            "Make as many wallpapers as you like from the same video. Each clip is exported as a separate wallpaper.",
        "Tramo seleccionado": "Selected Clip",
        "Bucle y optimización (todos los tramos)": "Loop and Optimization (all clips)",
        "Fundido": "Crossfade",
        "Sin fundido": "No crossfade",
        "0,5 s": "0.5 s",
        "Original": "Original",
        "Calidad": "Quality",
        "Alta": "High",
        "Media": "Medium",
        "Ligera": "Light",
        "Limitar a 30 fps": "Limit to 30 fps",
        "Mantener sonido": "Keep Sound",
        "Poner como fondo al terminar": "Set as Wallpaper When Done",
        "Vídeo original": "Original Video",
        "Guardar en «Originales» al cerrar": "Save to “Originals” on Close",
        "Podrás volver a abrirlo para sacar más fondos sin descargarlo otra vez (%@).":
            "You can reopen it to make more wallpapers without downloading it again (%@).",
        "Se borrará al cerrar el editor (%@).": "It will be deleted when you close the editor (%@).",
        "Creando fondos… (%d hechos)": "Creating wallpapers… (%d done)",
        "Cancelar exportación": "Cancel Export",
        "Crear %d fondos": "Create %d Wallpapers",
        "Crear fondo": "Create Wallpaper",
        "Crear solo el seleccionado": "Create Selected Only",
        "Cerrar": "Close",
        "Cerrar sin guardar": "Close Without Saving",
        "Quitar tramo": "Remove Clip",

        // YouTube sheet
        "Reintentar": "Try Again",
        " (bucle)": " (loop)",
        "Descargar de YouTube": "Download from YouTube",
        "Al terminar se abre el editor para elegir el bucle.": "When it finishes, the editor opens so you can pick the loop.",
        "Enlace del vídeo": "Video link",
        "Calidad máxima": "Maximum quality",
        "Falta: %@. Instala con «brew install yt-dlp ffmpeg».": "Missing: %@. Install with “brew install yt-dlp ffmpeg”.",
        "Descarga solo vídeos tuyos, con licencia libre o con permiso de su autor.":
            "Only download your own videos, freely licensed ones, or ones you have the author's permission for.",
        "Cancelar": "Cancel",
        "Descargar": "Download",
        "Descargando…": "Downloading…",
        "Analizando vídeo…": "Analyzing video…",
        "No se pudo leer el vídeo.": "Couldn't read the video.",
        "Convirtiendo a un formato compatible…": "Converting to a compatible format…",
        "No se pudo convertir el vídeo.": "Couldn't convert the video.",

        // Updates
        "Wallpy está actualizado": "Wallpy is up to date",
        "Tienes la última versión (%@).": "You have the latest version (%@).",
        "No se pudo buscar actualizaciones": "Couldn't check for updates",
        "Wallpy %@ está disponible": "Wallpy %@ is available",
        "Tienes la versión %@.": "You have version %@.",
        "Actualizar ahora": "Update Now",
        "Más tarde": "Later",
        "Omitir esta versión": "Skip This Version",
        "No se puede actualizar desde aquí": "Can't update from here",
        "Mueve Wallpy a la carpeta Aplicaciones, ábrela de nuevo y vuelve a intentarlo.":
            "Move Wallpy to the Applications folder, open it again and retry.",
        "No se puede actualizar": "Can't update",
        "No hay permiso para escribir en %@.\nUsa el instalador:\n\n%@": "No permission to write to %@.\nUse the installer:\n\n%@",
        "La versión %@ no incluye los archivos de actualización.": "Version %@ doesn't include the update files.",
        "La actualización falló": "Update failed",
        "GitHub no respondió correctamente. Inténtalo más tarde.": "GitHub didn't respond correctly. Try again later.",
        "El archivo descargado no coincide con su huella SHA-256. No se ha instalado nada.":
            "The downloaded file doesn't match its SHA-256 fingerprint. Nothing was installed.",
        "No se pudo descomprimir la actualización.": "Couldn't unzip the update.",
        "La descarga no contiene una versión válida de Wallpy.": "The download doesn't contain a valid version of Wallpy.",

        // Errors
        "«%@» no se puede reproducir con AVFoundation.": "“%@” can't be played with AVFoundation.",
        "«%@» no contiene pista de vídeo.": "“%@” has no video track.",
        "«%@» no es una imagen que macOS pueda abrir.": "“%@” isn't an image macOS can open.",
        "No se encuentra %@. Instálalo con: brew install %@": "%@ not found. Install it with: brew install %@",
        "Cancelado.": "Cancelled.",
        "%@ terminó con error %d.\n%@": "%@ exited with error %d.\n%@",
        "yt-dlp no devolvió ningún archivo.": "yt-dlp didn't return any file.",
        "Vídeo de YouTube": "YouTube video",
    ]

    static let ca: [String: String] = [
        // Menus
        "Cerrar ventana": "Tanca la finestra",
        "Salir de Wallpy": "Surt de Wallpy",
        "Edición": "Edició",
        "Deshacer": "Desfés",
        "Rehacer": "Refés",
        "Cortar": "Retalla",
        "Copiar": "Copia",
        "Pegar": "Enganxa",
        "Seleccionar todo": "Selecciona-ho tot",
        "Abrir biblioteca…": "Obre la biblioteca…",
        "Pausar fondos": "Posa en pausa els fons",
        "Silenciar": "Silencia",
        "Ocultar iconos del escritorio": "Amaga les icones de l'escriptori",
        "Abrir al iniciar sesión": "Obre en iniciar la sessió",
        "Actualizando…": "S'està actualitzant…",
        "Buscar actualizaciones…": "Cerca actualitzacions…",
        "Invítame a un café…": "Convida'm a un cafè…",

        // Library window
        "Sistema": "Sistema",
        "Idioma": "Idioma",
        "Biblioteca": "Biblioteca",
        "Originales": "Originals",
        "Ajustes": "Configuració",
        "Pantallas": "Pantalles",
        "Sin fondo": "Sense fons",
        "En pausa": "En pausa",
        "Reproduciendo": "Reproduint",
        "Se pausa cuando las ventanas tapan el escritorio.": "Es posa en pausa quan les finestres tapen l'escriptori.",
        "Se reproduce siempre.": "Es reprodueix sempre.",
        "Reanudar fondos": "Reprèn els fons",
        "Versión %@": "Versió %@",
        "Arrastra vídeos o imágenes aquí": "Arrossega vídeos o imatges aquí",
        "No se pudieron añadir algunos archivos": "No s'han pogut afegir alguns fitxers",
        "OK": "D'acord",
        "Este fondo está en uso. ¿Seguro que quieres eliminarlo?": "Aquest fons està en ús. Segur que el vols eliminar?",
        "Eliminar": "Elimina",
        "Importando…": "S'està important…",
        "Todo": "Tot",
        "Vídeos": "Vídeos",
        "Imágenes": "Imatges",
        "Buscar": "Cerca",
        "Desde YouTube…": "Des de YouTube…",
        "Añadir…": "Afegeix…",
        "Añadir": "Afegeix",
        "Vídeos: MP4, MOV, M4V. Imágenes: JPG, PNG, HEIC, WebP, TIFF. Los GIF se convierten en vídeo.":
            "Vídeos: MP4, MOV, M4V. Imatges: JPG, PNG, HEIC, WebP, TIFF. Els GIF es converteixen en vídeo.",
        "Poner en todas las pantallas": "Posa a totes les pantalles",
        "Poner en %@": "Posa a %@",
        "Recortar y optimizar…": "Retalla i optimitza…",
        "Mostrar en Finder": "Mostra al Finder",
        "En uso": "En ús",
        "Imagen": "Imatge",
        "Resolución baja": "Resolució baixa",
        "Nombre": "Nom",
        "Tipo": "Tipus",
        "Vídeo": "Vídeo",
        "Resolución": "Resolució",
        "Duración": "Durada",
        "Tamaño": "Mida",
        "En pantalla": "A la pantalla",
        "Eliminar de la biblioteca": "Elimina de la biblioteca",
        "Vídeos completos guardados para sacar más fondos sin volver a descargarlos.":
            "Vídeos complets desats per fer més fons sense tornar-los a baixar.",
        "Espacio usado": "Espai utilitzat",
        "Aún no hay originales": "Encara no hi ha originals",
        "Al descargar de YouTube, activa «Guardar en Originales» en el editor para conservar el vídeo completo.":
            "En baixar de YouTube, activa «Desa a Originals» a l'editor per conservar el vídeo complet.",
        "¿Eliminar «%@»? Los fondos ya creados a partir de él no se borran.":
            "Vols eliminar «%@»? Els fons ja creats a partir d'aquest vídeo no s'esborren.",
        "Guardado el %@": "Desat el %@",
        "Crear fondos": "Crea fons",
        "Eliminar original": "Elimina l'original",
        "Ninguno": "Cap",
        "Ahorro de energía": "Estalvi d'energia",
        "Pausar cuando las ventanas tapan el escritorio": "Posa en pausa quan les finestres tapen l'escriptori",
        "Recomendado: no gasta nada si no lo ves": "Recomanat: no gasta res si no el veus",
        "Pausar con batería baja": "Posa en pausa amb bateria baixa",
        "Por debajo de %d %%": "Per sota del %d %%",
        "Batería: %d %% · %@": "Bateria: %d %% · %@",
        "con batería": "amb bateria",
        "conectado": "connectat",
        "Sonido y escritorio": "So i escriptori",
        "Volumen": "Volum",
        "Actualizaciones": "Actualitzacions",
        "Buscar actualizaciones automáticamente": "Cerca actualitzacions automàticament",
        "Versión ": "Versió ",
        "Buscar ahora": "Cerca ara",
        "Herramientas": "Eines",
        "Instalado": "Instal·lat",
        "No instalado": "No instal·lat",
        "Necesarios para descargar de YouTube, el editor de bucles y convertir GIF.":
            "Necessaris per baixar de YouTube, l'editor de bucles i convertir GIF.",
        "Instálalos con: brew install yt-dlp ffmpeg": "Instal·la'ls amb: brew install yt-dlp ffmpeg",

        "Sin cargador": "Sense carregador",
        "Seguir": "Continua",
        "Pausar": "Pausa",
        "Imagen fija": "Imatge fixa",
        "Añade una imagen a la biblioteca para usarla aquí.": "Afegeix una imatge a la biblioteca per fer-la servir aquí.",
        "Elige una imagen": "Tria una imatge",
        "Mientras no esté enchufado, las pantallas con vídeo muestran esta imagen y el vídeo deja de gastar.":
            "Mentre no estigui endollat, les pantalles amb vídeo mostren aquesta imatge i el vídeo deixa de gastar.",
        "Aplicar también en modo de bajo consumo": "Aplica-ho també en mode de baix consum",
        "El modo de bajo consumo está activado": "El mode de baix consum està activat",
        "Sin fondos de vídeo": "Sense fons de vídeo",
        "Pausado desde el menú.": "En pausa des del menú.",
        "Sin cargador: los vídeos vuelven al enchufarlo.": "Sense carregador: els vídeos tornen en endollar-lo.",
        "Sin cargador: se muestra la imagen elegida.": "Sense carregador: es mostra la imatge triada.",
        "Batería baja.": "Bateria baixa.",
        "El Mac está muy caliente; se reanuda al enfriarse.": "El Mac està molt calent; es reprèn quan es refreda.",
        "Madrugada": "Matinada",
        "Mañana": "Matí",
        "Tarde": "Tarda",
        "Noche": "Nit",
        "Siempre": "Sempre",
        "Momentos del día": "Moments del dia",
        "desde": "des de",
        "Programación": "Programació",
        "No está programado en ningún momento.": "No està programat en cap moment.",
        "Abrir programación": "Obre la programació",
        "Elige qué fondo se ve en cada pantalla y en cada momento del día.": "Tria quin fons es veu a cada pantalla i a cada moment del dia.",
        "Cambiar según el momento del día": "Canvia segons el moment del dia",
        "Activa «Cambiar según el momento del día» para que se apliquen las columnas de los momentos. Mientras tanto se usa «Siempre».":
            "Activa «Canvia segons el moment del dia» perquè s'apliquin les columnes dels moments. Mentrestant es fa servir «Sempre».",
        "Pantalla": "Pantalla",
        "Ahora": "Ara",
        "Fondo base": "Fons base",
        "Usa Siempre": "Fa servir Sempre",
        "Pincha una casilla para elegir el fondo. «Siempre» es el fondo base de cada pantalla: se ve en los momentos que no tengan uno propio.":
            "Fes clic en una casella per triar el fons. «Sempre» és el fons base de cada pantalla: es veu en els moments que no en tinguin un de propi.",
        "%@ · %@": "%@ · %@",
        "Aplicar a todas las pantallas": "Aplica a totes les pantalles",
        "Añade fondos en la Biblioteca para programarlos.": "Afegeix fons a la Biblioteca per programar-los.",
        "Quitar el fondo": "Treu el fons",
        "Usar el de Siempre": "Fes servir el de Sempre",
        // Loop editor
        "Editor de bucle — %@": "Editor de bucle — %@",
        "Editor de bucle": "Editor de bucle",
        "DENTRO DEL BUCLE": "DINS DEL BUCLE",
        "Ir a la entrada (↑)": "Ves a l'entrada (↑)",
        "Fotograma anterior (←)": "Fotograma anterior (←)",
        "Reproducir / pausa (Espacio)": "Reprodueix / pausa (Espai)",
        "Fotograma siguiente (→)": "Fotograma següent (→)",
        "Ir a la salida (↓)": "Ves a la sortida (↓)",
        "Entrada": "Entrada",
        "Marcar entrada (I)": "Marca l'entrada (I)",
        "Salida": "Sortida",
        "Marcar salida (O)": "Marca la sortida (O)",
        "Repetir tramo": "Repeteix el tram",
        "Reproducir solo entre entrada y salida (L)": "Reprodueix només entre l'entrada i la sortida (L)",
        "Duración del bucle": "Durada del bucle",
        "Ajustar al tramo": "Ajusta al tram",
        "Ver todo": "Mostra-ho tot",
        "Arrastra para buscar · bordes azules: entrada/salida · ⌥ arrastrar: mover tramo · clic en la franja de tramos: seleccionar · N nuevo tramo · I / O marcan · Espacio reproduce · ← → fotograma · ⇧← ⇧→ 1 s · + / − zoom":
            "Arrossega per cercar · vores blaves: entrada/sortida · ⌥ arrossegar: mou el tram · clic a la franja de trams: selecciona · N tram nou · I / O marquen · Espai reprodueix · ← → fotograma · ⇧← ⇧→ 1 s · + / − zoom",
        "Mapa del vídeo completo: arrastra para moverte por la línea de tiempo": "Mapa del vídeo complet: arrossega per moure't per la línia de temps",
        "Nuevo tramo en el cabezal (N)": "Tram nou al capçal (N)",
        "Tramos (%d)": "Trams (%d)",
        "Haz tantos fondos como quieras del mismo vídeo. Cada tramo se exporta como un fondo independiente.":
            "Fes tants fons com vulguis del mateix vídeo. Cada tram s'exporta com un fons independent.",
        "Tramo seleccionado": "Tram seleccionat",
        "Bucle y optimización (todos los tramos)": "Bucle i optimització (tots els trams)",
        "Fundido": "Fosa",
        "Sin fundido": "Sense fosa",
        "0,5 s": "0,5 s",
        "Original": "Original",
        "Calidad": "Qualitat",
        "Alta": "Alta",
        "Media": "Mitjana",
        "Ligera": "Lleugera",
        "Limitar a 30 fps": "Limita a 30 fps",
        "Mantener sonido": "Mantén el so",
        "Poner como fondo al terminar": "Posa-ho com a fons en acabar",
        "Vídeo original": "Vídeo original",
        "Guardar en «Originales» al cerrar": "Desa a «Originals» en tancar",
        "Podrás volver a abrirlo para sacar más fondos sin descargarlo otra vez (%@).":
            "Podràs tornar a obrir-lo per fer més fons sense baixar-lo de nou (%@).",
        "Se borrará al cerrar el editor (%@).": "S'esborrarà en tancar l'editor (%@).",
        "Creando fondos… (%d hechos)": "S'estan creant els fons… (%d fets)",
        "Cancelar exportación": "Cancel·la l'exportació",
        "Crear %d fondos": "Crea %d fons",
        "Crear fondo": "Crea el fons",
        "Crear solo el seleccionado": "Crea només el seleccionat",
        "Cerrar": "Tanca",
        "Cerrar sin guardar": "Tanca sense desar",
        "Quitar tramo": "Elimina el tram",

        // YouTube sheet
        "Reintentar": "Torna-ho a provar",
        " (bucle)": " (bucle)",
        "Descargar de YouTube": "Baixa de YouTube",
        "Al terminar se abre el editor para elegir el bucle.": "En acabar, s'obre l'editor per triar el bucle.",
        "Enlace del vídeo": "Enllaç del vídeo",
        "Calidad máxima": "Qualitat màxima",
        "Falta: %@. Instala con «brew install yt-dlp ffmpeg».": "Falta: %@. Instal·la-ho amb «brew install yt-dlp ffmpeg».",
        "Descarga solo vídeos tuyos, con licencia libre o con permiso de su autor.":
            "Baixa només vídeos teus, amb llicència lliure o amb permís del seu autor.",
        "Cancelar": "Cancel·la",
        "Descargar": "Baixa",
        "Descargando…": "S'està baixant…",
        "Analizando vídeo…": "S'està analitzant el vídeo…",
        "No se pudo leer el vídeo.": "No s'ha pogut llegir el vídeo.",
        "Convirtiendo a un formato compatible…": "S'està convertint a un format compatible…",
        "No se pudo convertir el vídeo.": "No s'ha pogut convertir el vídeo.",

        // Updates
        "Wallpy está actualizado": "Wallpy està actualitzat",
        "Tienes la última versión (%@).": "Tens l'última versió (%@).",
        "No se pudo buscar actualizaciones": "No s'han pogut cercar actualitzacions",
        "Wallpy %@ está disponible": "Wallpy %@ està disponible",
        "Tienes la versión %@.": "Tens la versió %@.",
        "Actualizar ahora": "Actualitza ara",
        "Más tarde": "Més tard",
        "Omitir esta versión": "Omet aquesta versió",
        "No se puede actualizar desde aquí": "No es pot actualitzar des d'aquí",
        "Mueve Wallpy a la carpeta Aplicaciones, ábrela de nuevo y vuelve a intentarlo.":
            "Mou Wallpy a la carpeta Aplicacions, torna-la a obrir i torna-ho a provar.",
        "No se puede actualizar": "No es pot actualitzar",
        "No hay permiso para escribir en %@.\nUsa el instalador:\n\n%@": "No hi ha permís per escriure a %@.\nFes servir l'instal·lador:\n\n%@",
        "La versión %@ no incluye los archivos de actualización.": "La versió %@ no inclou els fitxers d'actualització.",
        "La actualización falló": "L'actualització ha fallat",
        "GitHub no respondió correctamente. Inténtalo más tarde.": "GitHub no ha respost correctament. Torna-ho a provar més tard.",
        "El archivo descargado no coincide con su huella SHA-256. No se ha instalado nada.":
            "El fitxer baixat no coincideix amb la seva empremta SHA-256. No s'ha instal·lat res.",
        "No se pudo descomprimir la actualización.": "No s'ha pogut descomprimir l'actualització.",
        "La descarga no contiene una versión válida de Wallpy.": "La baixada no conté una versió vàlida de Wallpy.",

        // Errors
        "«%@» no se puede reproducir con AVFoundation.": "«%@» no es pot reproduir amb AVFoundation.",
        "«%@» no contiene pista de vídeo.": "«%@» no conté cap pista de vídeo.",
        "«%@» no es una imagen que macOS pueda abrir.": "«%@» no és una imatge que macOS pugui obrir.",
        "No se encuentra %@. Instálalo con: brew install %@": "No es troba %@. Instal·la'l amb: brew install %@",
        "Cancelado.": "Cancel·lat.",
        "%@ terminó con error %d.\n%@": "%@ ha acabat amb l'error %d.\n%@",
        "yt-dlp no devolvió ningún archivo.": "yt-dlp no ha retornat cap fitxer.",
        "Vídeo de YouTube": "Vídeo de YouTube",
    ]
}
