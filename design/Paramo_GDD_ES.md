# PÁRAMO — Documento de Diseño

**Género:** Simulación de Conservación / Estrategia
**Motor:** Godot 4
**Plataforma:** Desktop (horizontal)
**Duración:** 30-45 min por partida
**Estética:** Pixel art serio y atmosférico. Referencia: Dome Keeper.

---

## Tesis Central

**El páramo opera en tiempo geológico. Los humanos destruyen en tiempo industrial.**

Cada mecánica refuerza esta asimetría. Un frailejón tarda siglos en crecer y segundos en arder. Una ladera minada tarda décadas en revegetarse. El juego no se trata de ganar — se trata de resistir, de administrar, de tomar decisiones imposibles sobre qué salvar cuando no puedes salvarlo todo.

La conservación no es una batalla que se gana. Es un compromiso que se mantiene.

El juego busca que las mecánicas generen reflexiones duraderas sobre los sistemas socio-ecológicos reales. Que el jugador sienta profundamente la fragilidad de estos ecosistemas: lo fácil que es destruir, lo lento que es reparar, lo imposible que es revertir ciertas pérdidas. Que entienda que un páramo no es un recurso renovable sino un sistema irreemplazable, formado en escalas de tiempo que la vida humana no alcanza a comprender.

Y que la destrucción no viene solo de villanos — viene de personas con necesidades, de sistemas legales que la permiten, de decisiones políticas lejanas, de la acumulación silenciosa de pequeños daños. El jugador debe terminar cada partida con preguntas incómodas: sobre qué sacrificó, a quién ignoró, qué se perdió mientras miraba para otro lado. No porque el juego lo sermonee, sino porque lo vivió.

---

## Concepto

Eres el coordinador de campo de una ONG que protege un páramo andino colombiano — un ecosistema tropical de alta montaña único en el mundo. El páramo es una "fábrica de agua": sus frailejones capturan niebla, sus musgos retienen humedad, su laguna glaciar alimenta ríos que abastecen a millones.

Las amenazas suben desde abajo — mineros, turistas, ganado, especuladores, especies invasoras. Amenazas ambientales golpean desde todas las direcciones — sequía, incendio, erosión, cambio climático. Debes recorrer físicamente la montaña para plantar, construir, investigar y responder, mientras administras tu organización desde una estación de investigación.

En la cumbre: una laguna glaciar. Si muere, todo muere.

Al terminar, el jugador debería entender intuitivamente por qué estos ecosistemas importan, por qué desaparecen, y por qué protegerlos es un reto difícil pero supremamente importante.

### Principio de diseño: rigor ante todo

Toda decisión mecánica, estética y narrativa debe estar respaldada por evidencia científica, social o cultural real. Las tasas de crecimiento de frailejones, los patrones de flujo hídrico, el comportamiento de pastos invasores, las dinámicas entre comunidades rurales y áreas protegidas, la representación del territorio — nada se inventa por conveniencia lúdica. Si una mecánica no refleja la realidad del páramo y su contexto humano, se rediseña hasta que lo haga. El juego pierde autoridad como herramienta de reflexión si sacrifica la verdad por la jugabilidad.

---

## La Montaña

Mapa de una montaña vista en perspectiva isométrica. Ancha en la base, angosta hacia la cumbre. La laguna en la cima.

La **altitud** es una variable continua que modifica todo: velocidad de crecimiento vegetal, exposición a amenazas humanas vs. ambientales, velocidad del jugador, generación de agua. No hay biomas predefinidos — la zonación emerge del gameplay.

### Tiles

Cada tile tiene:
- **Salud ecosistémica:** Saludable > Estresado > Degradado > Árido > Cicatrizado
- **Humedad:** Según proximidad al agua, estación y salud
- **Biodiversidad:** Riqueza de especies por tile — impulsa resiliencia

**Estado inicial:** Mixto. El páramo alto está mayormente sano pero con estrés climático. La zona media tiene daño ganadero y pasto invasor. La base muestra cicatrices agrícolas y un sitio minero abandonado. Como jugador inicialmente heredas un paisaje herido.

### Flujo de Agua

El agua se genera arriba (frailejones capturan niebla, la laguna filtra, musgos retienen lluvia) y fluye cuesta abajo por arroyos. Tiles cerca del agua son más fértiles. Si se interrumpe la generación de agua arriba, todo abajo se estresa.

Canales de agua permiten redirigir el flujo — pero sacar agua de un camino seca otro. Cada redirección es un tradeoff.

### La Laguna

Cabecera de toda la montaña. Tiene un **medidor de pureza** que se degrada por escorrentía minera, sedimentación, contaminación turística.

- Pureza <75%: generación de agua reducida 25%
- Pureza <50%: el apoyo comunitario cae (su agua se deteriora)
- Pureza <25%: fallo en cascada — tiles altos mueren sin importar su estado
- Pureza 0%: **Game over**

Lección clave: proteger la laguna requiere actuar montaña abajo, mucho antes de que cualquier amenaza llegue a la cumbre.

---

## Recursos

| Recurso | Función | Si cae críticamente... |
|---|---|---|
| **Agua** | Plantar, apagar incendios, sostener ecosistema, abastecer comunidades río abajo | Cascada de muerte vegetal, restauración imposible |
| **Fondos** | Infraestructura, personal, acciones legales, programas comunitarios | 0 por 2+ estaciones = la ONG cierra. Game over. |
| **Apoyo Comunitario** | Modificador global: alto = menos amenazas humanas, rangers más efectivos, casos legales más fuertes. Bajo = más invasión, vandalismo, cobertura política para minería | No se gasta directamente — amplifica o debilita todo |

**Intención de diseño:** La conservación que ignora a las comunidades fracasa. Un jugador que solo construye cercas y contrata seguridad perderá porque el apoyo comunitario colapsa y las amenazas se multiplican.

---

## El Jugador

Entidad física en el mapa. Debe moverse para interactuar. La cámara lo sigue — solo ves tus alrededores inmediatos, no el mapa completo.

### Visibilidad

- Radio de visión base alrededor del jugador
- **Estaciones de monitoreo** revelan tiles permanentemente dentro de su radio
- Tiles fuera de visión muestran su **último estado conocido** (información desactualizada)
- **Audio direccional:** sonidos de amenazas fuera de pantalla (motosierras, fuego, turistas) — jugadores experimentados aprenden a leer el audio
- **Fase de planificación:** única vez que ves el mapa completo

### Niveles de Interacción

| Nivel | Dónde | Acciones |
|---|---|---|
| **1 — Presencia física** | En el tile | Plantar, construir, apagar fuegos, confrontar mineros, recolectar muestras |
| **2 — Estación** | En la base | Gastar fondos, casos legales, subvenciones, mapa estratégico, programas comunitarios |
| **3 — Radio** | Cualquier tile (requiere upgrade) | Recibir alertas, ver recursos, comandar rangers |

**Tensión central:** Cada momento en la estación es un momento fuera del campo. Cada momento en el campo es un momento en que la organización funciona en piloto automático. Siempre estás eligiendo qué descuidar.

---

## Herramientas del Jugador

### Plantas (cuestan agua y fondos, efecto lento)
- **Frailejones:** Solo en alta montaña. 3-4 estaciones para madurar. Máxima generación de agua. Si arden, desaparecen — siglos de crecimiento, segundos de fuego.
- **Arbustos nativos:** Altitudes bajas-medias. Rápidos (1 estación). Estabilizan tiles degradados.

### Infraestructura (cuestan fondos)
- **Senderos:** Redirigen turistas, generan ingresos, crean rutas rápidas. Pero atraen más turistas.
- **Cercas:** Bloquean acceso físico. Efectivas pero exceso = baja apoyo comunitario.
- **Estaciones de monitoreo:** Detección temprana, evidencia para casos legales, investigación.
- **Canales de agua:** Redirigen flujo, irrigan, crean cortafuegos. Tradeoff: redirigir agua seca otra ruta.
- **Señalización:** Convierte turistas ignorantes en turistas conscientes. Barata y pasiva.

### Personal (costo de fondos continuo por estación)
- **Rangers:** Patrullan, interceptan ilegales. Efectividad depende del apoyo comunitario.
- **Educadores comunitarios:** Generan apoyo, reducen amenazas de agricultores. LA respuesta al dilema del campesino desesperado.
- **Equipo legal:** Único recurso contra minería legal. Éxito ~50%, mejorado por evidencia y apoyo comunitario.

---

## Amenazas

Las amenazas no siguen caminos fijos. Entran por los bordes y se mueven hacia objetivos. Degradan los tiles que ocupan. **El mapa ES la barra de vida.**

### Biológicas
- **Pastos invasores:** Expansión lenta y silenciosa. Peligrosos precisamente porque no son dramáticos.
- **Ganado feral:** Pisotean vegetación. Más frecuentes con bajo apoyo comunitario.

### Humanas — Ignorantes
- **Turistas casuales:** Pisotean frailejones, dejan basura. No maliciosos — solo inconscientes.
- **Turistas imprudentes:** Encienden fogatas (RIESGO DE INCENDIO), contaminan la laguna.

### Humanas — Extractivas
- **Mineros ilegales:** Rápidos y devastadores. Degradan tiles a Cicatrizado en 1-2 turnos.
- **Minería legal:** Llega con permisos. No puedes atacarla — solo impugnarla legalmente. Lenta pero metódica y devastadora. El jugador debe experimentar la frustración de ver destrucción permitida que no puede detener físicamente.

### Humanas — Desesperadas
- **Campesinos de subsistencia:** Daño bajo pero persistente. Removerlos por fuerza baja apoyo comunitario. La solución mecánicamente óptima (educación + alternativas económicas) coincide con la éticamente óptima. Jugadores que tratan a campesinos como enemigos perderán.

### Ambientales
- **Sequía:** Baja generación de agua, maximiza riesgo de fuego. Empeora cada año.
- **Lluvia fuerte:** Erosión en tiles degradados. Tiles sanos resisten.
- **Incendio forestal:** Se propaga. Frailejones secos son extremadamente inflamables. Estaciones de crecimiento borradas en segundos.
- **Cambio climático:** Modificador de fondo. Cada año la temperatura sube, las sequías se alargan, el rango viable de frailejones sube. No tiene contramedida. Es el reloj debajo de todo.

---

## Estaciones y Ritmo

Cada año tiene dos estaciones:

| | Verano (Seco) | Invierno (Lluvioso) |
|---|---|---|
| Agua | Reducida ~40% | Máxima |
| Riesgo principal | Fuego, turismo alto, minería activa | Erosión, visibilidad reducida |
| Restauración | No se puede plantar | Más efectiva |
| Movimiento | Normal | Lento (barro, arroyos crecidos) |

**1 partida = 5 años (10 estaciones).** Entre estaciones: fase de planificación (mapa completo, gastar fondos, reposicionar).

---

## Victoria y Derrota

### Derrota
- Pureza de la laguna llega a 0%
- Salud total del ecosistema bajo 20%
- Fondos en 0 por 2+ estaciones consecutivas

### "Victoria"
Sobrevivir 10 estaciones con la laguna viva y el ecosistema sobre el umbral crítico.

No hay pantalla triunfal. El final muestra la montaña — cicatrizada o preservada, lo que sea que el jugador logró. Los frailejones plantados en la Estación 1... siguen de pie? Las cicatrices son visibles. Nada se borra.

---

## Bucles de Retroalimentación

### Ciclos virtuosos (lentos de construir)
- Tiles sanos arriba > agua > fertilidad abajo > restauración > más tiles sanos
- Programas comunitarios > menos amenazas > menos daño > más ecoturismo > más fondos
- Frailejones maduros > captura de niebla > agua > más capacidad de siembra

### Espirales de muerte (rápidos de activar)
- Tiles degradados arriba > menos agua > plantas mueren abajo > menos agua > laguna se seca
- Bajo apoyo comunitario > más invasión > más daño > menos ingresos > menos programas > menos apoyo
- Fuego destruye frailejones > baja agua > peor sequía > más fuego

**Los ciclos virtuosos tardan estaciones en construirse. Las espirales de muerte se activan en una mala estación. Esta asimetría ES el mensaje.**
