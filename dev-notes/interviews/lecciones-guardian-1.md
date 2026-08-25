# Lecciones de campo — Jaime Avellaneda (Agua Somos, Chingaza)

Puntos y consecuencias de diseño de la conversación con **Jaime Avellaneda**, guardián y habitante de páramo del macizo de Chingaza, vinculado al fondo de agua Agua Somos (agosto 2026). Notas crudas: `Guardian_1.txt`.

Esto **no** es la transcripción. Es lo que cambia, confirma o contradice el diseño de Paramo. Cada punto apunta al sistema que toca; donde el GDD ya dice algo, va la línea.

## La tesis, dicha por alguien que vive ahí

> "el biólogo deja por fuera al campesino... incluso se pone el valor ambiental encima del humano. lo tenemos que cuidar TODOS, no solo el biólogo."

La premisa central del juego debe ser social. La mayor amenaza al páramo es el ser humano en todas sus dimensiones: turismo (legal e ilegal), extractivismo económico, burocracia y protocolo reduciendo la gobernanza nativa.

Corolario que sí es nuevo: el antagonista no es necesariamente el campesino **ni** el extractor, es el modelo que despoja a la comunidad de gobernanza.

## "37 páramos, todos diferentes. Un solo reglamento no sirve"

Validación parcial de la estrategia de mapas procedurales por run: la respuesta correcta a un páramo no transfiere al siguiente. Si cada montaña generada trae distinta mezcla de altitudes, humedad y presión humana, el jugador aprende principios en vez de memorizar una solución — que es exactamente lo que él dice que le falta a la política pública.

Implicaciones : 
1. la solución óptima no debería ser estable entre runs. Si existe un orden de construcción que siempre gana, el juego contradice su propia fuente.
2. debe realizarse mayor investigación-participación para tomar argumentos de diferentes comunidades en diferentes páramos.

## La comunidad no es un escalar

Él la descompone en 4+ actores con intereses distintos: habitante de páramo, propietario de tierra, urbano, local. "cada uno hace cosas diferentes y necesita cosas diferentes."

El GDD tiene **una** barra de apoyo comunitario, y eso colapsa un conflicto en un número. Debe cambiar a ser más dinámico.

Su palabra para la solución es **gobernanza**: acuerdos entre público, privado y comunidad. No "ganarse a la gente", sino negociar entre partes que no quieren lo mismo ni tienen potestades iguales.

## Amenazas: su ranking real

1. **Ganadería extensiva** — coincide con la prensa y con `Paramo_GDD.md:391`.
2. **Cacería** — perros de caza, perros ferales, cazadores. **El GDD no la modela**; solo aparece como blanco de guardaparques.
3. **Turismo masivo** — no el turista suelto, sino la escala y quién la controla.

Matiz que cambia el diseño de la ganadería: él **acepta** actividades agropecuarias — "ganado muy cercado (que no sea desmedido)". El problema no es la vaca, es la vaca sin manejo. La distinción no es amenaza contra no-amenaza sino manejado contra desmedido. Un rebaño cercado que convive debería ser un estado terminal válido, no algo que el jugador erradica.

### Cacería y fauna (falta en el GDD)

Amenaza invisible: no degrada tiles, vacía biodiversidad. No la detectas patrullando, la detectas **después**, por ausencia. Encaja con la cámara trampa (abajo) como único medio de detección, y con el oso de anteojos como especie bandera cuya desaparición es el marcador.

Los perros ferales son la versión que ni siquiera tiene un dueño a quien negociarle.

### Turismo: falta el antagonista de infraestructura

El GDD modela turistas individuales (`:399`, `:406`) y la infraestructura de ecoturismo como herramienta del jugador (`:360`). Falta la pregunta que a él le da miedo:

> "temor porque los páramos tienen vocación de turismo. Una multinacional puede hacer infra de peso, se desborda el turismo y daña el ecosistema completamente."

Es decir: **el turismo como amenaza corporativa legal**, hermana de la minería con permiso. Alguien construye acceso pesado, el volumen se dispara, el ecosistema se cae — y es legal, y trae plata, y parte de la comunidad la quiere. Un tercer actor de destrucción permitida junto a minería legal y especuladores.

La pregunta que él deja abierta —"¿quién debe hacerlo? ¿comunidades a baja escala o industria a gran escala? ¿quién lo regula?"— es una decisión de jugador, no una amenaza a repeler.

### Los senderos también hacen daño

> "senderos dañan flora, basura, compactación daña el suelo completamente."

El GDD trata los senderos como positivos con un solo costo: atraen más turistas (`:288`). Falta el costo físico. El sendero **compacta el suelo por debajo**, y la compactación es lo que él describe como el daño total — el suelo del páramo es la esponja, no la planta.

Propuesta: el sendero convierte sus propios tiles a un estado degradado permanente o de recuperación muy lenta. Concentrar el daño es la razón de ser del sendero, no un efecto secundario; el jugador elige **dónde** sacrificar suelo. Eso lo vuelve una decisión y no una mejora obvia.

## El agua que se va a la ciudad y no se paga

> "captaciones de agua para las ciudades: campesinos no reciben ninguna compensación ni parte del agua."
> "ej: que el turista pague por dañar."

Ausente por completo del GDD, y es el eje del mundo real: los fondos de agua tipo Agua Somos existen precisamente por esto — pago por servicios ambientales aguas arriba, financiado aguas abajo.

Es el hueco de diseño más grande que salió de la conversación, porque reencuadra al jugador. Si el agua del mapa alimenta una ciudad que no aparece en pantalla, y esa ciudad paga —o no paga— a quien vive arriba, entonces el jugador no es un defensor neutral: administra una extracción. Mecánicamente:

- El agua producida por el mapa se va y genera financiación.
- Si esa financiación no vuelve como compensación a los habitantes, el apoyo cae aunque el ecosistema esté sano.
- "Que el turista pague por dañar" es la misma idea por el otro lado: tarifas que convierten impacto en presupuesto de restauración.

Esto le da al juego una economía con una postura, en vez de tres recursos abstractos.

## La cámara trampa hace tres cosas, no una

Su rutina real: mínimo una vez al mes coloca cámaras trampa, y sirven para **biodiversidad, detección de amenaza (perros de caza, ferales, cazadores) e historia y ecoturismo**.

La estación de monitoreo del GDD solo detecta (`:299`, `:185`). Convertirla en cámara trampa con tres salidas —dato de biodiversidad, alerta de amenaza, y material que alimenta ecoturismo o el diario de campo— la vuelve mucho más interesante, y es literalmente lo que se hace en el terreno. También conecta directo con el field journal: las fotos de fauna son el contenido natural de las páginas de flora y fauna conocida.

Resto del día: patrullar (turismo ilegal, cazadores) y revisar anomalías — derrumbes, sequías que dejan sin agua de consumo **a los animales**, crecidas cuando llueve ocho días seguidos.

En el juego, uno de los dispositivos pueden ser cámaras trampa que hagan una espewcie de notificación al ver algo. 

## Clima: falta niebla, helada, y más efectos de lluvia y sequía.

El GDD ya tiene sequías, lluvias fuertes, incendio y deriva climática. De su día a día salen dos que no están, y que son baratas de construir sobre los sistemas existentes:

- **Heladas** — "cielo estrellado, temperatura bajo cero". Ocurre en noches despejadas, o sea después de un día bueno, y daña plantas jóvenes. Un riesgo que castiga precisamente la noche que se ve más bonita.
- **Niebla** — "la neblina hace que se oscurezca mucho. En verano es hermoso con mucha visibilidad."
- **efectos fluviales** - el río se crece y se seca con la temporada, afectando mobilidad.

La niebla es visibilidad, y el juego ya tiene fog-of-war y ciclo día/noche. La estación seca da visión larga y riesgo de incendio alto; la húmeda, poca visión y poco fuego. Eso hace que la información sea estacional sin agregar un sistema nuevo: **ver y quemarse son la misma estación.**

## Restauración: lenta, frágil y social

> "reforestación es difícil, toma tiempo y es frágil. específico a cada ecosistema. reforestación igual tiene un aspecto social."

Dos consecuencias. La primera ya está bien encaminada: el frailejón tarda, y quemarlo es la peor pérdida del juego (`:466`). La segunda no está: restaurar tiene una dimensión social — quién siembra, en tierra de quién, quién cuida después. Sembrar sin acuerdo debería poder fracasar por razones humanas, no solo climáticas.

Programas de reforestación también cumplen un rol educativo y comunicativo.

## El protocolo como exclusión

Su queja concreta: los parques exigen guías con certificación profesional del SENA, lo que **deja por fuera a los niños y jóvenes de las comunidades** que crecieron ahí. Pide "menos arbitrariedad y protocolo, más comunicación y participación".

Material de evento, no de amenaza: una regulación que suena responsable, que protege algo real, y que al mismo tiempo le quita el sustento a la gente del lugar. El tipo de decisión sin lado bueno que el juego dice querer.

## Tensiones sin resolver

- **Cercas.** El GDD dice que generan resentimiento (`:341`, `:364`). Él dice que el ganado bien cercado es la forma correcta de convivir. Probablemente ambas son ciertas y depende de quién puso la cerca y quién quedó del lado de afuera — pero el modelo actual no distingue, y debería.
- **Turismo.** Es amenaza y es el sustento que hace viable la reserva. Cualquier diseño donde el turismo sea solo daño o solo ingreso es infiel a la fuente.
- **Un mapa contra 37 páramos.** El slice manda una montaña por run; el punto de él es que ninguna receta transfiere. Verificar que la simulación de balance no esté convergiendo a una estrategia dominante.
