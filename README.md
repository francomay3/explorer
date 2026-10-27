# Explorer

Borrador de un explorador de archivos para Mac, en el espíritu del Explorador clásico de Windows: árbol de carpetas a la izquierda, lista a la derecha, atrás, adelante y subir.

No usa la red.

## Correrlo

```bash
make run
make test
```

Abre tu carpeta de usuario. La primera vez que entres a Escritorio, Documentos o Descargas, macOS pide permiso para esa carpeta.

## Cómo está armado

`Sources/ExplorerCore` sabe de carpetas y no conoce la ventana. `Sources/Explorer` es la ventana. Una feature nueva entra por uno de estos lugares:

- Otra operación (copiar, mover): `FileActions.swift`, un ítem en `MainMenu.swift` y el método en `MainWindowController`.
- Otro formato en la vista previa: un tipo nuevo en `FilePreviews.swift`, y agregarlo a `providers`. Los de más arriba ganan.
- Otra columna: `FileItem`, `Sorting.swift` y `FileListController`.
- Pestañas u otra ventana: un `BrowserStore` por vista. La ventana ya tiene el suyo.
- Buscar dentro de la carpeta: filtrar `snapshot.items` en `BrowserStore` y un campo junto a la barra de dirección.

## Qué hace hoy

- Árbol con tu casa y los discos, carpetas ocultas incluidas
- Lista: nombre, tamaño, tipo, fecha. Las carpetas van primero
- Iconos. Shift+clic marca el tramo. Arrastrarlos a una carpeta (en el panel o en el árbol) los mueve
- Vista previa de todo el contenido: imagen, texto y un cuadro del video. Lo demás dice que no hay vista previa
- Atrás, adelante, subir
- La dirección es un texto: se edita y Enter abre esa ruta
- Doble clic abre la carpeta o el archivo
- Carpeta nueva, renombrar, tirar a la Papelera

## Qué queda para después

Copiar y pegar, pestañas, y búsqueda. La búsqueda filtraría `snapshot.items` por nombre, sin salir de la carpeta.
