# Z-Value

[![Versión de Zig](https://img.shields.io/badge/zig-0.17.0-orange.svg)](https://ziglang.org/)
[![Licencia: MIT](https://img.shields.io/badge/Licencia-MIT-blue.svg)](LICENSE)

**Z-Value** es un tipo `JSValue` de unión etiquetada con conteo de referencias, para el ecosistema de micro-librerías [z-*](https://github.com/carlos-sweb) escrito en Zig 0.17.0. Es la pieza que conecta las primitivas ECMAScript independientes y de tipado estático — [z-array](https://github.com/carlos-sweb/z-array), [z-object](https://github.com/carlos-sweb/z-object), [z-string](https://github.com/carlos-sweb/z-string), [zregex](https://github.com/carlos-sweb/z-regex), [z-symbol](https://github.com/carlos-sweb/z-symbol), [z-map](https://github.com/carlos-sweb/z-map), [z-set](https://github.com/carlos-sweb/z-set), [z-error](https://github.com/carlos-sweb/z-error), [z-date](https://github.com/carlos-sweb/z-date), [z-promise](https://github.com/carlos-sweb/z-promise), [z-bigint](https://github.com/carlos-sweb/z-bigint), [z-buffer](https://github.com/carlos-sweb/z-buffer) — en algo que realmente puede representar un valor JS heterogéneo: una variable, un elemento de array, o una propiedad de objeto que puede ser un número hoy y un string mañana.

[🇬🇧 English Version](README.md)

## Por qué existe

`ZArray(T)` y `ZObject(T)` son genéricos pero **monomórficos** — un solo `T` fijo por instancia, como cualquier contenedor genérico en un lenguaje de tipado estático. Un array JS real (`[1, "a", true]`) es heterogéneo, algo que `ZArray(T)` solo no puede representar. `JSValue` es el `T` que hace que `ZArray(JSValue)` / `ZObject(JSValue)` se comporten como arrays/objetos JS reales — esto refleja cómo V8 y QuickJS comparten internamente una única representación de valor unificada (`Tagged<Object>` / `JSValue` respectivamente) entre `Array`, `Object`, `Number`, etc., en vez de mantener cada tipo completamente independiente.

## Diseño

- **Unión etiquetada, no NaN-boxing**: `undefined`/`null`/`boolean`/`number` van inline (bits trivialmente copiables); `string`/`array`/`object`/`regex`/`symbol`/`map`/`set` son heap-owning y viven detrás de un puntero a una caja con conteo de referencias.
- **Reference counting** (estilo QuickJS), no un tracing GC: predecible, sin pausas, pero **no** recolecta ciclos de referencias — ver [Limitaciones Conocidas](#limitaciones-conocidas).
- **No invasivo**: z-array/z-object/z-string/zregex/z-symbol/z-map/z-set/z-error/z-date/z-promise/z-bigint/z-buffer no saben nada de z-value. La caja `Rc(T)` en `src/rc.zig` los envuelve desde afuera; ninguno de esos proyectos tuvo que cambiar su propio diseño para esto (z-symbol sí ganó un agregado chico y autocontenido — ver [Soporte por variante](#soporte-por-variante) — pero nada específico de z-value se filtró ahí). Dos variantes, `function` (`Callable`) y `proxy` (`Proxy`), no tienen ningún repo hermano — se definen directamente en este repo (`src/callable.zig`, `src/proxy.zig`) porque no tienen sentido fuera de un grafo de `JSValue` (el par `ctx`/`call` de un callable y el par `target`/`handler` de un Proxy son conceptos nativos de z-value, no estructuras de datos de propósito general).
- **`JSValue` soporta el mismo duck-typing de igualdad genérica que cualquier otro struct/union**: expone `eql(a, b) bool` (SameValueZero) y `hash(self) u64`, detectados automáticamente por la maquinaria genérica de [z-equality](https://github.com/carlos-sweb/z-equality) — esto es lo que permite que `ZMap(JSValue, JSValue)`/`ZSet(JSValue)` funcionen. (z-equality ganó soporte genérico para uniones etiquetadas por esto; ver su propio README.)

## Reglas de Ownership

Zig no tiene copy constructors ni destructores, así que esto es una **convención**, no algo que el compilador imponga:

- Copiar un `JSValue` por asignación **no** toca el contador de referencias.
- Llamá `.retain()` explícitamente cuando una copia necesite sobrevivir al binding original (ej. guardar el mismo valor en dos contenedores).
- Llamá `.deinit()` exactamente una vez por cada referencia retenida/propia. `deinit()` decrementa el contador y solo destruye el valor subyacente cuando llega a cero — el mismo hábito `defer value.deinit()` que ya se usa en toda la familia z-*, solo que ahora significa "libero *mi* referencia".
- **Nunca llames `ZArray(JSValue).clone()` ni los helpers de copia de propiedades de `ZObject(JSValue)` directamente.** Ambos son copias superficiales por bytes que no retienen sus elementos, así que dos "clones" terminarían compartiendo cajas con el contador sin incrementar → doble-free o liberación prematura. Usá `JSValue.cloneArray()` / `JSValue.cloneObject()` / `JSValue.cloneMap()` / `JSValue.cloneSet()` / `JSValue.cloneError()` en su lugar, que retienen cada hijo correctamente. (`ZMap`/`ZSet`/`ZError` no exponen hoy su propio `clone()` superficial, así que no hay un landmine equivalente que evitar ahí — `cloneMap()`/`cloneSet()`/`cloneError()` existen por simetría de API y porque de todos modos vas a necesitar duplicado consciente de Rc.)

```zig
var arr = try JSValue.newArray(allocator);
const child = try JSValue.newString(allocator, "shared");
try arr.array.value.items.append(allocator, child.retain()); // retain: arr ahora comparte ownership
child.deinit();  // libera la referencia del binding original
arr.deinit();    // libera la referencia propia de arr a child, recursivamente
```

## Soporte por variante

| Variante | Estado | Notas |
|---|---|---|
| `undefined` / `null` / `boolean` / `number` | ✅ Completo | Inline, sin asignación de memoria |
| `string` | ✅ Completo | `*Rc(ZString)` de [z-string](https://github.com/carlos-sweb/z-string) — semántica completa de ECMAScript String indexada en UTF-16. `JSValue.newString()` siempre construye un `ZString` *owned* (`initOwned`, nunca el modo *borrowed* de `init`), ya que el `deinit()` de un `ZString` borrowed es un no-op y rompería silenciosamente el contrato de refcounting de Rc. |
| `array` | ✅ Completo | `*Rc(ZArray(JSValue))`, liberación recursiva, `cloneArray()` |
| `object` | ✅ Completo | `*Rc(ZObject(JSValue))`, liberación recursiva, `cloneObject()`. Ver el gap de prototype abajo. |
| `regex` | ✅ Completo | `*Rc(Regex)` de zregex, sin JSValues anidados que recorrer |
| `symbol` | ✅ Completo | `*Rc(ZSymbol)` de [z-symbol](https://github.com/carlos-sweb/z-symbol). `JSValue.newSymbol()` usa `ZSymbol.init()` (un valor, no la asignación propia de `create()`) para que la caja Rc sea la única asignación real del símbolo; z-symbol ganó un `ZSymbol.deinit()` a juego (libera solo la descripción, no `self`) para esto — `destroy()` sigue siendo `deinit()` + liberar self, para uso standalone (no envuelto en Rc). `typeOf()` es `"symbol"`, su propio resultado distinto (no `"object"`). |
| `map` | ✅ Completo | `*Rc(ZMap(JSValue, JSValue))` de [z-map](https://github.com/carlos-sweb/z-map). Liberación recursiva de claves *y* valores (a diferencia de `object`, cuyas claves son strings planos, las claves de `Map` también son `JSValue` arbitrarios). `cloneMap()`. |
| `set` | ✅ Completo | `*Rc(ZSet(JSValue))` de [z-set](https://github.com/carlos-sweb/z-set). Liberación recursiva de valores. `cloneSet()`. |
| `error` | ✅ Completo | `*Rc(ZError(JSValue))` de [z-error](https://github.com/carlos-sweb/z-error). `newError()`/`newAggregateError()`. Liberación recursiva de los `JSValue` anidados de `AggregateError`. `cloneError()`. `typeOf()` es `"object"` (los errores son objetos en JS: `typeof new TypeError() === "object"`). Se comparan por identidad de caja, igual que `array`/`object`/etc. |
| `function` | ✅ Completo | `*Rc(Callable)` — definido en este repo (`src/callable.zig`), sin repo hermano. `ctx: *anyopaque` + `call: *const fn(...) anyerror!JSValue`, deliberadamente opaco para que este repo siga siendo independiente de cualquier familia de parser/intérprete; el tipo concreto de `ctx` (función nativa, closure de usuario, ...) es elección total del consumidor. `newFunction()`. `typeOf()` es `"function"`, su propio resultado distinto (no `"object"`). |
| `date` | ✅ Completo | `*Rc(ZDate)` de [z-date](https://github.com/carlos-sweb/z-date), un valor puro de 8 bytes (un timestamp en milisegundos) — sin `JSValue`s anidados que recorrer. `newDate(ms)`. |
| `promise` | ✅ Completo | `*Rc(ZPromise(JSValue))` de [z-promise](https://github.com/carlos-sweb/z-promise) — solo almacena/transiciona estado, nunca invoca callbacks por sí mismo (eso es trabajo del consumidor, ej. la cola de jobs de un intérprete). `newPromise()`. |
| `bigint` | ✅ Completo | `*Rc(ZBigInt)` de [z-bigint](https://github.com/carlos-sweb/z-bigint), enteros de precisión arbitraria. `newBigInt(rawDigitText)` (parsea) / `newBigIntFromValue(v)`. **La única variante en el heap que se compara/hashea por VALOR, no por identidad de caja Rc** (`1n === 1n` es `true` entre dos instancias parseadas independientemente) — ver los comentarios de [`equality.zig`](src/equality.zig). |
| `proxy` | ✅ Completo | `*Rc(Proxy)` — definido en este repo (`src/proxy.zig`), sin repo hermano. Un par `target`/`handler` sin datos ni algoritmo propio; pura indirección de despacho de traps, interpretada enteramente por quien lea esos campos de vuelta. `newProxy(target, handler)`. `typeOf()` recursa en `target.typeOf()` (un proxy que envuelve un callable reporta `"function"`), pero la igualdad/hash son por identidad de caja PROPIA del Proxy (dos proxies sobre el mismo target nunca son `===`). |
| `array_buffer` | ✅ Completo | `*Rc(ArrayBuffer)` de [z-buffer](https://github.com/carlos-sweb/z-buffer). Almacenamiento de bytes de longitud fija, inicializado en cero; hoja para el GC (sin `JSValue`s anidados). `newArrayBuffer(byteLength)`. |
| `data_view` | ✅ Completo | `*Rc(DataViewBox)` — definido en este repo (`src/data_view_box.zig`), envuelve un `zbuffer.DataView` (endianness explícita por llamada) más el `JSValue` `.array_buffer` dueño sobre el que lee/escribe. Misma convención de ownership que `proxy`: `owner` se libera en `deinit`, pero el constructor no lo retiene por vos. `newDataView(owner, byteOffset, byteLength)`. |
| `typed_array` | ✅ Completo | `*Rc(TypedArrayBox)` — definido en este repo (`src/typed_array_box.zig`): una ventana de byte-offset/cantidad-de-elementos sobre un `JSValue` `.array_buffer` dueño, más una etiqueta `TypedKind` para los 11 tipos de elemento visibles en JS (`i8`/`u8`/`u8_clamped`/`i16`/`u16`/`i32`/`u32`/`f32`/`f64`/`i64`/`u64` — `u8`/`u8_clamped` comparten el mismo almacenamiento subyacente, difiriendo solo en la coerción de escritura y la identidad JS). `TypedKind` vive deliberadamente ACÁ y no en z-buffer: el framing "clamped" es específico de TypedArray/JS, no un concepto general de buffers. Misma convención de ownership que `proxy`/`data_view`. `newTypedArray(owner, byteOffset, len, kind)`. |

## Limitaciones Conocidas

- **`ZObject.prototype` no tiene conteo de referencias.** Es un `?*Self` crudo heredado de z-object sin gestión de lifetime propia — z-value no lo retiene ni lo libera. Si se libera un objeto prototipo mientras otro objeto todavía lo referencia, ese puntero queda colgante. Arreglar esto requeriría que z-object se vuelva consciente de Rc (o exponga un hook genérico de retain/release); fuera de alcance acá.
- **Los ciclos de referencias generan fugas.** Un array/objeto que (directa o indirectamente) contiene un `JSValue` que apunta de vuelta a sí mismo nunca llega a contador cero. No hay colector de ciclos en esta versión — romper los ciclos es responsabilidad del caller.
- **Se asume single-threaded.** `Rc(T).count` es un `usize` plano, no atómico. Un consumidor multi-hilo necesitaría atomics acá.
- **Un `retain()`/`deinit()` desbalanceado solo se detecta en Debug/ReleaseSafe.** `Rc.decref()` verifica con assert que el contador nunca haga underflow; en `ReleaseFast` ese assert se compila afuera y el underflow es comportamiento indefinido. Ejercitá siempre rutas nuevas de refcounting bajo `std.testing.allocator` en un build Debug primero.

## Documentación API

Requiere **Zig 0.17.0**. Consulta la [documentación API de Zig](https://carlos-sweb.github.io/z-value/), generada directamente desde las declaraciones públicas y los comentarios del código.

Para generarla localmente:

```sh
zig build docs
python3 -m http.server 8000 --directory zig-out/docs
```

Abre `http://localhost:8000/`. El workflow `API documentation` ejecuta las pruebas, genera la documentación y la publica en GitHub Pages con cada push a `master`.

## Instalación

Todas las dependencias usan releases etiquetadas de GitHub con hashes verificados en `build.zig.zon`:
```zig
.dependencies = .{
    .zarray = .{
        .url = "https://github.com/carlos-sweb/z-array/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "zarray-0.1.0--NF-nREsAgCIst1d1GpxPxSW9kD23R9YsHfLFutfI3BI",
    },
    .zobject = .{
        .url = "https://github.com/carlos-sweb/z-object/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "zobject-0.1.0-dBSRhEALAgBp6grSV2T8Xv5jJ5fuP6jEKxssv0WzYHfI",
    },
    .zregex = .{
        .url = "https://github.com/carlos-sweb/z-regex/archive/refs/tags/v0.9.1.tar.gz",
        .hash = "zregex-0.9.1-c2ExG-nXtQC7-ZMaj_xLvyK4lGk4qSYJIQVlp-umRsBh",
    },
    .zstring = .{
        .url = "https://github.com/carlos-sweb/z-string/archive/refs/tags/v0.4.1.tar.gz",
        .hash = "z_string-0.4.1-_tPTB3qvcgCABVSF3Nw8kUjZglYyXpnEZVJWWKlZETJL",
    },
    .zsymbol = .{
        .url = "https://github.com/carlos-sweb/z-symbol/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "zsymbol-0.1.0--_-46A5FAADblMb_Etysuux6m0d6eekqqGcosK9eoVoC",
    },
    .zmap = .{
        .url = "https://github.com/carlos-sweb/z-map/archive/refs/tags/0.1.0.tar.gz",
        .hash = "zmap-0.1.0-rJUj4vovAABdj36zmPiFpDaj-FNuOg171FhdYOPPO_qg",
    },
    .zset = .{
        .url = "https://github.com/carlos-sweb/z-set/archive/refs/tags/0.1.0.tar.gz",
        .hash = "zset-0.1.0-wFuBtLQuAACmEGDqSGAPvhEHNqkVbwVEWf6gDmrRKomb",
    },
    .zerror = .{
        .url = "https://github.com/carlos-sweb/z-error/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "zerror-0.1.0-bDg2UR8zAABuBVoyyvyYhoJsjYDE2oNWsillDSp_9gzo",
    },
    .zdate = .{
        .url = "https://github.com/carlos-sweb/z-date/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "zdate-0.1.0-f1RpEfhuGwBUqJ87i0el4VP-9O2z8x7XIJP9fwWH8BvA",
    },
    .zpromise = .{
        .url = "https://github.com/carlos-sweb/z-promise/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "zpromise-0.1.0-y0pjffwoAAD6EpxTPIleE2tiU9RuUbKbDIz-iotebE_u",
    },
    .zbigint = .{
        .url = "https://github.com/carlos-sweb/z-bigint/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "zbigint-0.1.0-PA8m8TgNAQDF0cJPy3JN67NMRsXgqJUCJlEatiV66rMQ",
    },
    .zbuffer = .{
        .url = "https://github.com/carlos-sweb/z-buffer/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "zbuffer-0.1.0-bUHCsDXIAAB1Yt5RcFhEApi6XO8NeV32ia8WvM3QttNv",
    },
    .ztemporal = .{
        .url = "https://github.com/carlos-sweb/z-temporal/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "ztemporal-0.1.0-9l_8_jt7BgDitcgR0ACQLBddaQqIK4nfJAEEDvNKDs5Z",
    },
},
```

## Estructura del Proyecto

```
z-value/
├── src/
│   ├── zvalue.zig         # unión JSValue, constructores, retain()/deinit(), cloneArray()/cloneObject()/cloneMap()/cloneSet()/cloneError()
│   ├── rc.zig              # Caja genérica de conteo de referencias Rc(T)
│   ├── equality.zig        # strictEquals/sameValueZero/hash/JSValueHashContext
│   ├── errors.zig
│   ├── callable.zig        # Callable (payload de la variante `function`) -- sin repo hermano
│   ├── proxy.zig           # Proxy (payload de la variante `proxy`) -- sin repo hermano
│   ├── data_view_box.zig   # DataViewBox (payload de la variante `data_view`)
│   └── typed_array_box.zig # TypedArrayBox + TypedKind (payload de la variante `typed_array`)
├── tests/
│   ├── value_types_test.zig
│   ├── rc_test.zig
│   ├── array_test.zig
│   ├── object_test.zig
│   ├── regex_test.zig
│   ├── symbol_test.zig
│   ├── map_test.zig
│   ├── set_test.zig
│   ├── error_test.zig
│   ├── equality_test.zig
│   ├── callable_test.zig
│   ├── date_test.zig
│   ├── bigint_test.zig
│   ├── proxy_test.zig
│   ├── data_view_box_test.zig
│   └── typed_array_box_test.zig
├── build.zig
└── build.zig.zon
```

## Correr los Tests

```bash
zig build test
```

## Licencia

MIT
