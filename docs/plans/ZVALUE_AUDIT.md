# Auditoría de z-value — inventario, problemas y propuestas

Fecha: 2026-10-05 · Rama: `claude/affectionate-einstein-8vbpot` (= `master`, HEAD `4fbd249`)
Alcance: solo lectura. No se ha tocado código de z-value. Este archivo es el único cambio en el árbol, y no se ha hecho commit.

Convenciones del documento:
- **[medido]**: cifra obtenida ejecutando algo (tests, `@sizeOf`, `wc`, el binario z-run).
- **[contado]**: cifra obtenida con `grep`/`wc`. Es exacta sobre el texto, pero aproximada sobre la semántica.
- **[estimado]**: juicio o extrapolación, sin medir.
- Las rutas `archivo:línea` se refieren a z-value HEAD salvo que se indique otro repo. Los commits de los repos hermanos consultados: z-interpreter `0d0e0d4`, z-json `37b4606`, z-toml `f77ea76`, z-yaml `252db7c`, z-run `96380f5`, z-object `6e9a613`, z-equality `6c70f6c`, z-array `9e13105`, z-map `13de45a`, z-set `3390e97`.

Cómo se obtuvo la evidencia:
- Zig 0.16.0 (paquete `ziglang` de PyPI, porque ziglang.org está bloqueado por el proxy). Caches y salida van al scratchpad (`--cache-dir`, `--global-cache-dir`, `-p`).
- Los repos hermanos se clonaron en `/home/user/z-*`, que es la ruta `../z-*` que espera `build.zig.zon`.
- **Suite propia de z-value: 97/97 tests pasan, 36/36 pasos [medido].**
- Los reproductores están en un proyecto aparte del scratchpad (`repro/repro.zig`, 25 tests). Usan `std.testing.FailingAllocator` y el detector de fugas de `std.testing.allocator`. **Resultado: 18 bugs confirmados (16 con fugas, 114 asignaciones fugadas en total; 2 fallos de aserción) y 6 controles positivos que pasan [medido].**
- Otro proyecto de reproducción (`repro2/`) importa z-toml y z-yaml: los dos casos producen un **panic `reached unreachable code`** [medido].
- Se compiló z-run y se ejecutaron 13 scripts JS de una línea [medido].

---

## 1. Inventario

### 1.1 Estructura del repositorio

| Archivo | Líneas [medido] | Qué hace |
|---|---:|---|
| `src/zvalue.zig` | 618 | `JSValue` (unión de 21 variantes), constructores, `typeOf`, `eql`/`hash` (hook duck-typed para z-equality), `retain`, `setGcHook`, `deinit` (destrucción recursiva) y `clone{Array,Object,Map,Set,Error}` |
| `src/equality.zig` | 108 | `strictEquals` (`===`), `sameValueZero`, `hash` y `JSValueHashContext` |
| `src/rc.zig` | 76 | `Rc(T)`: caja con refcount, allocator y hook de GC opcional |
| `src/typed_array_box.zig` | 52 | `TypedKind` (11 tipos) y `TypedArrayBox` (owner + offset + len + kind) |
| `src/callable.zig` | 48 | `Callable` (ctx opaco, `call`, `name`, `arity`, `prototype`, `constructable`, `statics`) |
| `src/temporal_value.zig` | 39 | `TemporalValue`: una unión con los 8 tipos de z-temporal |
| `src/data_view_box.zig` | 24 | `DataViewBox` (`zbuffer.DataView` + owner) |
| `src/proxy.zig` | 20 | `Proxy { target, handler }` |
| `src/errors.zig` | 3 | `ZValueError = Allocator.Error` |
| **Total src/** | **988** | |
| `tests/*.zig` (17 archivos) | 1039 | 97 tests |
| `build.zig` / `build.zig.zon` | 71 / 29 | |

**Dependencias.** `build.zig.zon` declara 13 dependencias, todas con `.path = "../z-*"`: zarray, zobject, zregex, zstring, zsymbol, zmap, zset, zerror, zdate, zpromise, zbigint, zbuffer y ztemporal. Además hay 2 dependencias transitivas que también deben estar presentes: `z-number` (a través de z-string) y `z-equality` (a través de z-array y z-map). z-string trae z-regex por URL git, fijado en `85afd1f`.

Consecuencia: z-value **no se puede compilar en solitario**. Hacen falta 15 repos hermanos en `../`. En una máquina limpia, el primer `zig build` falla con `unable to open '../z-number'` [medido].

**`build.zig`.**
- Una sola lista `dep_names` alimenta el fetch, el módulo `zvalue` y los `addImport` de los tests.
- Cada uno de los 17 archivos de test es un artefacto independiente.
- `default_step = test`.
- Los tests importan también las 13 dependencias directamente.

### 1.2 `JSValue`: las 21 variantes

`@sizeOf(JSValue) = 16 B` [medido]: 8 B de payload, más el tag y el padding.

| # | Variante | Almacenamiento | Payload | Caja [medido] | Payload [medido] | ¿Contiene JSValues? | Constructor |
|---|---|---|---|---:|---:|---|---|
| 1 | `undefined` | inline | `void` | — | — | — | `UNDEFINED` |
| 2 | `null` | inline | `void` | — | — | — | `NULL` |
| 3 | `boolean` | inline | `bool` | — | — | — | `fromBool` |
| 4 | `number` | inline | `f64` | — | — | — | `fromNumber` |
| 5 | `string` | Rc | `ZString` (owned) | 96 | 56 | no | `newString` |
| 6 | `array` | Rc | `ZArray(JSValue)` | 80 | 40 | sí (elementos) | `newArray`, `cloneArray` |
| 7 | `object` | Rc | `ZObject(JSValue)` | 112 | 72 | sí (valores, getters y setters) | `newObject`, `cloneObject` |
| 8 | `regex` | Rc | `zregex.Regex` | 840 | 800 | no | `fromRegex` |
| 9 | `symbol` | Rc | `ZSymbol` | 72 | 32 | no | `newSymbol` |
| 10 | `map` | Rc | `ZMap(JSValue,JSValue)` | 96 | 56 | sí (claves y valores) | `newMap`, `cloneMap` |
| 11 | `set` | Rc | `ZSet(JSValue)` | 96 | 56 | sí | `newSet`, `cloneSet` |
| 12 | `error` | Rc | `ZError(JSValue)` | 96 | 56 | sí (`errors` de AggregateError) | `newError`, `newAggregateError`, `cloneError` |
| 13 | `function` | Rc | `Callable` | 136 | 96 | sí (`prototype`, `statics`) | `newFunction` |
| 14 | `date` | Rc | `ZDate` (valor puro) | 48 | 8 | no | `newDate` |
| 15 | `promise` | Rc | `ZPromise(JSValue)` | 96 | 56 | sí (`result`, reacciones) | `newPromise` |
| 16 | `bigint` | Rc | `ZBigInt` | 80 | 40 | no | `newBigInt`, `newBigIntFromValue` |
| 17 | `proxy` | Rc | `Proxy` | 72 | 32 | sí (`target`, `handler`) | `newProxy` |
| 18 | `array_buffer` | Rc | `zbuffer.ArrayBuffer` | 80 | 40 | no | `newArrayBuffer`, `newSharedArrayBuffer` |
| 19 | `data_view` | Rc | `DataViewBox` | 80 | 40 | sí (`owner`) | `newDataView` |
| 20 | `typed_array` | Rc | `TypedArrayBox` | 80 | 40 | sí (`owner`) | `newTypedArray` |
| 21 | `temporal` | Rc | `TemporalValue` (valor puro) | 144 | 96 | no | `newTemporal` |

Cabecera fija de `Rc(T)` [medido]: 40 B (count + allocator + 2 punteros del hook de GC).

**Criterio inline/Rc.** La regla real es que solo van inline los 4 tipos sin heap y sin identidad. Todo lo demás va en Rc, también los primitivos con heap (string, bigint) y los valores puros con identidad (date, temporal).

El criterio es **consistente**, pero la documentación no lo refleja:
- `zvalue.zig:48-50` dice "string/array/object/regex are heap-owning", un texto que se quedó en la versión de 4 variantes.
- `rc.zig:4-7` enumera solo "ZArray, ZObject, Regex, ZString".

**Destrucción** (`deinit`, `zvalue.zig:392-534`): un `switch` exhaustivo. En cada caso hace `decref()` y, si el contador llega a 0:
1. libera los JSValues anidados,
2. llama a `value.deinit()` cuando el payload lo tiene (date y temporal no lo tienen),
3. llama a `box.destroy()`.

**`retain`** (`zvalue.zig:327-349`) incrementa el contador y no hace nada en las variantes inline. Devuelve `self` para poder encadenar.

**Qué garantiza `Rc(T)`** (`rc.zig:14-75`):
- `create` arranca con `count = 1`.
- `retain` hace `count += 1`.
- `decref` hace `assert(count > 0)` y luego `count -= 1`. El assert solo existe en Debug/ReleaseSafe; en ReleaseFast un underflow es UB.
- `destroy` llama al hook de GC (si existe) y libera la caja.

Lo que `Rc(T)` **no** garantiza:
- No llama a `value.deinit()`; esa política vive en `JSValue.deinit`.
- No es thread-safe: el contador es un `usize` no atómico.
- No detecta ciclos.
- `setGcHook` sobrescribe en silencio un hook anterior.

### 1.3 Ownership: reglas documentadas

1. Copiar un JSValue por asignación **no** toca el refcount. Hay que llamar a `retain()` cada vez que la copia sobrevive al original, y a `deinit()` una vez por referencia (`zvalue.zig:57-64`).
2. `ZArray.clone()` y los helpers de copia de ZObject son superficiales. Para `T = JSValue` hay que usar `clone*()` (`zvalue.zig:62-64`).
3. Los constructores que reciben JSValues (`newAggregateError`, `newProxy`, `newDataView`, `newTypedArray`) **toman posesión sin retener**: quien llama hace `retain()` antes si quiere conservar su propia referencia (`zvalue.zig:154-159, 210-214, 241-243`; `proxy.zig:4-11`).
4. `fromRegex`, `newBigIntFromValue` y `newTemporal` toman posesión del valor que reciben.
5. Huecos conocidos y documentados (`zvalue.zig:382-391`):
   - `ZObject.prototype` es un `?*Self` crudo, sin refcount, y puede quedar colgando.
   - Los ciclos se fugan, porque z-value no tiene colector. z-interpreter tiene el suyo propio.

**Sitios con `retain`/`deinit`/`decref` en `src/` (sin comentarios) [contado]:**
- 22 `.retain()`
- 39 `.deinit()`
- 18 `decref()`
- 6 `errdefer`, que están en `newDataView`, `newTypedArray` y los 4 `clone*`. **Ningún constructor `new*` que haga dos asignaciones tiene `errdefer` entre la primera y la segunda.**

**El fix de `newString`:** **no está en HEAD.** Está en la rama remota `origin/gpt-sol-z-value` (commit `c5515bb`, "fix: release owned string data when Rc allocation fails"). Ese commit cambia `const str` por `var str` y añade `errdefer str.deinit();`, además de un test. Por inspección corrige exactamente R01 (más abajo). **El mismo defecto existe en otros 4 constructores y en los 5 `clone*`**, y el fix no los toca.

### 1.4 Igualdad y hashing

| Operación | Implementación | Semántica |
|---|---|---|
| `equality.strictEquals` (`equality.zig:18-50`) | Si el tag es distinto devuelve `false`. Si no, decide por variante. | `number`: delega en `zarray.equality` (`NaN !== NaN`, `+0 === -0`). `string`: compara bytes. `bigint`: compara **por valor** (`ZBigInt.eql`). Las 15 variantes restantes comparan **por identidad de caja** (puntero Rc). |
| `equality.sameValueZero` (`:60-67`) | Igual que la anterior, salvo `NaN == NaN` | Correcta para Map, Set e `includes`. |
| `equality.hash` (`:73-97`) | Inline: constantes. Number: hash canonicalizado (NaN y ±0 unificados en z-equality). String: hash de bytes. Bigint: `ZBigInt.hash()`. Resto: hash del puntero. | Consistente con `sameValueZero` [medido, control CTRL Map key]. |
| `JSValue.eql` (`zvalue.zig:313-315`) | **`sameValueZero`** | Es el hook duck-typed que usa z-equality **para todo** (ver P-EQ1). |
| `JSValueHashContext` (`equality.zig:99-108`) | hash + `sameValueZero` | Contexto para `std.HashMap`. |

Las decisiones de identidad son correctas según ECMAScript: string y bigint son primitivos, por eso se comparan por valor; array, object, map y el resto son objetos, por eso se comparan por identidad. Temporal y Date también van por identidad, lo cual es correcto.

**Interacción con z-equality.** `zequality.strictEquals(T, a, b)`, cuando `T` es una unión que declara `eql`, llama a `T.eql` (`z-equality/src/zequality.zig:4-19, 64-69`). Como `JSValue.eql` es SameValueZero, **todo `strictEquals` genérico sobre `JSValue` se comporta en realidad como SameValueZero**. Ese es el bug P-EQ1.

### 1.5 La ausencia de bolsa de propiedades

Hoy solo 2 de las 21 variantes tienen dónde guardar propiedades propias con nombre:
- `object`: su payload *es* la bolsa (`ZObject(JSValue)`).
- `function`: `Callable.statics`, una bolsa perezosa (`callable.zig:30-36`).

Las otras 12 variantes de tipo objeto no tienen dónde guardarlas: array, regex, map, set, error, date, promise, array_buffer, data_view, typed_array, temporal y proxy. Proxy no debe tener bolsa propia, porque reenvía al target.

Cómo resuelve esto cada consumidor:

| Consumidor | Estrategia | Evidencia |
|---|---|---|
| **z-interpreter** | Usa **tablas laterales** en `Interpreter`, indexadas por `@intFromPtr(box)`: `array_props` (solo para `index`/`input`/`groups` de los resultados de exec/match), `regex_state` (lastIndex y flags), `primitive_wrapper_data` y `deleted_fn_props`. También usa `Callable.statics` para las funciones. Para el resto devuelve `error.NotImplemented`. | `z-interpreter/src/interpreter.zig:654-680`; `interpreter_props.zig:403-516` (la línea 516 dice `if (obj != .object) return error.NotImplemented;`) |
| z-json, z-toml, z-yaml | No lo resuelven. Solo serializan `array` y `object`. | — |
| z-run | No lo resuelve. Delega en z-interpreter. | — |

Comportamiento real, medido con el binario z-run compilado desde los repos actuales:

```
const m = new Map();  m.x = 1        -> z-run: NotImplemented
const s = new Set();  s.x = 1        -> NotImplemented
new Date(0).x = 1                    -> NotImplemented
new Error("a").code = 42             -> NotImplemented   (solo .message es escribible)
Promise.resolve(1).tag = 1           -> NotImplemented
new ArrayBuffer(8).x = 1             -> NotImplemented
new Uint8Array(4).x = 1              -> NotImplemented
/a/.x = 1                            -> NotImplemented   (solo lastIndex)
[1].x = 1                            -> OK (tabla lateral array_props)
function f(){}; f.x = 1              -> OK (Callable.statics)
({}).x = 1                           -> OK
Object.defineProperty(new Map(),"x",{value:1}) -> TypeError: Object.defineProperty called on non-object
```

**De 11 tipos de objeto probados, 8 no admiten propiedades propias [medido].** El caso `defineProperty` es además un error de clasificación: un Map *es* un objeto.

Efecto colateral: **las claves símbolo.** Como `ZObject` solo admite claves `[]const u8`, z-interpreter codifica los símbolos como `"\x00S<ptr>"`, donde `<ptr>` es la dirección de la caja (`interpreter_expr.zig:304-321`), y los nombres privados como `"\x00P<ptr>|name"`. Hay dos consecuencias:
1. Esa convención **se ha filtrado a z-json, z-toml y z-yaml**, que la conocen y la filtran (`key[0] == 0`): `zjson.zig:256`, `zyaml.zig:752, 787`, `ztoml.zig:696, 738, 751`.
2. La clave no retiene el símbolo. Si la caja se libera y otra reutiliza la misma dirección, la propiedad cambia de dueño. Esto **no está medido** (ver §4).

### 1.6 Consumidores de z-value

Hay 5 repos que declaran `zvalue` en su `build.zig.zon` [contado]. Ningún otro repo de `carlos-sweb/z-*` lo hace.

| Consumidor | Líneas .zig | Archivos que mencionan zvalue | Uso principal |
|---|---:|---:|---|
| z-interpreter | 23 762 | 45 | Todo: las 21 variantes, los 20 constructores, retain/deinit, `setGcHook`, `PropertyDescriptor`, `Rc(` (20 usos) |
| z-run | 2 841 | 9 | `newObject` (14), `newFunction` (5) y `UNDEFINED` (9). Expone API nativa al intérprete. |
| z-json | 1 020 | 5 | parse/stringify. `switch` **exhaustivo** sobre las 21 variantes. |
| z-toml | 1 238 | 6 | parse/stringify. `switch` con `else`. |
| z-yaml | 1 269 | 5 | parse/stringify. `switch` con `else`. |

Referencias a variantes en z-interpreter [contado, heurístico: `.tag =>` o `.tag,` en archivos que importan zvalue]: entre 15 y 40 por variante, ~474 en total.

| Variante | Refs | Variante | Refs | Variante | Refs |
|---|---:|---|---:|---|---:|
| array | 40 | set | 24 | proxy | 19 |
| object | 35 | null | 24 | number | 19 |
| function | 27 | undefined | 23 | boolean | 18 |
| string | 26 | map | 22 | date | 18 |
| symbol | 21 | bigint | 21 | error | 17 |
| promise | 20 | regex | 20 | typed_array | 16 |
| temporal | 15 | data_view | 15 | array_buffer | 15 |

API usada por z-interpreter [contado]:
- `fromNumber` 238, `UNDEFINED` 211, `fromBool` 126
- `deinit()` 292 y `retain()` 249 (estos dos incluyen `deinit` de otros tipos)
- `typeOf` 56, `PropertyDescriptor` 45, `strictEquals` 12
- los 20 constructores, casi siempre envueltos en `gcNew*`, que hacen `new*` + `gcTrack`. Hay 22 llamadas crudas a `JSValue.new*`, la mayoría dentro de esos envoltorios.
- **No usa ningún `clone*`.**

---

## 2. Problemas encontrados

Gravedad: **A** = corrupción, panic o divergencia de semántica JS visible. **B** = fuga, solo con OOM o con uso incorrecto. **C** = documentación, tests o diseño.

### P-EQ1 (A): `strictEquals` genérico sobre JSValue se comporta como SameValueZero

- **Causa:** `JSValue.eql` es SameValueZero (`zvalue.zig:313-315`), y z-equality lo usa también para `strictEquals` (`zequality.zig:64-69`). Las funciones de z-array que deben usar `===`, que son `indexOf`, `lastIndexOf` y `count` (`z-array/src/methods/search.zig:19, 36, 201`), terminan usando SameValueZero.
- **Reproductor R13** [medido]: con `[NaN].indexOf(NaN)` se esperaba `null` y se obtiene `0`.
- **Extremo a extremo** [medido]: `console.log([NaN].indexOf(NaN), [NaN].includes(NaN))` en z-run imprime `0 true`. En JS debe imprimir `-1 true`.
- El comentario de `zvalue.zig:306-312` dice que Map/Set es "the only consumer of this method today". **Es falso.**
- Diferencias `+0`/`-0`: SameValueZero y `===` coinciden, así que no hay divergencia.

### P-OWN1 (B): constructores que fallan sin liberar la primera asignación

Todos siguen el patrón `const x = try Payload.init(...); return .{ .tag = try Rc.create(...) }` sin `errdefer`.

| Rep. | Constructor | Línea | Fuga [medido] |
|---|---|---|---|
| R01 | `newString` | `zvalue.zig:104-105` | 1 asignación (bytes del ZString). El fix está en `origin/gpt-sol-z-value`, no en HEAD. |
| R02 | `newSymbol` | `:130-131` | 1 (descripción) |
| R03 | `newError` | `:150-151` | 1 (mensaje) |
| R04 | `newBigInt` | `:197-198` | 1 (limbs) |
| R05 | `newArrayBuffer` | `:219-220` | 1 (bytes). `newSharedArrayBuffer` (`:229-231`) tiene el mismo patrón, por inspección. |
| — | `fromRegex`, `newBigIntFromValue` | `:120-122`, `:206-208` | Por inspección: si `Rc.create` falla, el valor que se entregó en posesión no se libera, y quien llama no puede saber si debe liberarlo. |

### P-OWN2 (B): contrato "toma posesión" inconsistente cuando hay error

- `newDataView` y `newTypedArray` hacen `errdefer owner.deinit()` (`:248`, `:265`), así que liberan lo recibido si fallan. Control CTRL verificado.
- `newProxy` (`:212-214`) y `newAggregateError` (`:160-163`) no lo hacen. Con OOM se fugan `target`/`handler` y los `errs` recibidos. **R06: 8 asignaciones; R07: 2 [medido].**
- z-interpreter llama a `gcNewProxy(target.retain(), handler.retain())` (`proxy_builtins.zig:38`): ese camino fuga con OOM, y añadir un `errdefer` en z-value lo arregla sin provocar doble liberación.

### P-OWN3 (B): los `clone*` no limpian si fallan a mitad

`errdefer new_x.deinit()` libera el contenedor, pero no los JSValues ya retenidos dentro de él (`ZArray`, `ZObject`, `ZMap` y `ZSet` no liberan sus T). Además, el valor retenido en la llamada que falla tampoco se libera.

| Rep. | Función | Líneas | Fuga [medido] |
|---|---|---|---|
| R08 | `cloneArray` | `:541-547` | 4. Los hijos ya retenidos quedan con +1 si `Rc.create` falla. |
| R09 | `cloneObject` | `:553-566` | 26 |
| R10 | `cloneMap` | `:574-586` | 38 |
| R11 | `cloneSet` | `:589-599` | 8 |
| R12 | `cloneError` | `:605-617` | 14. El `errdefer` falta por completo; si `initAggregate` o `Rc.create` fallan, `retained` se pierde. |

Ningún consumidor usa hoy `clone*` [contado], así que el impacto real es nulo por ahora. Es deuda latente.

### P-SEM1 (A): `cloneObject` no es un clon fiel

`cloneObject` (`zvalue.zig:553-566`) itera `keys()`, que filtra las propiedades no enumerables (`zobject.zig:331-345`), y lee con `get()`, que devuelve el placeholder en lugar del accessor. Pierde 4 de 4 atributos [medido, R14]:
1. las propiedades no enumerables,
2. getters y setters (los convierte en datos `undefined`),
3. los flags (`frozen`, `sealed`, `extensible`) y los descriptores,
4. el prototipo. El doc comment de `:550-552` es ambiguo: insinúa que se copia algo, pero queda a `null`.

Puede ser un diseño deliberado, una "copia de valores enumerables" al estilo `Object.assign`. Si es así, el nombre y el doc lo ocultan.

### P-OWN4 (B): las APIs de mutación de los contenedores no conocen Rc, y z-value no ofrece envoltorios

z-value expone `box.value.set(...)`, `.add(...)` y `.push(...)` crudos. Las reglas de liberación del valor viejo recaen en cada consumidor:

| Rep. | Operación | Fuga [medido] | Causa |
|---|---|---|---|
| R15 | `ZObject.set` sobre un accessor | 1 | Pone `getter`/`setter = null` sin liberarlos (`zobject.zig:123-125`) |
| R16 | `ZObject.set` sobre una clave existente | 2 | Sobrescribe `value` sin liberar el anterior |
| R17 | `ZMap.set` con una clave igual a una existente | 4 | `put` conserva la clave vieja: la nueva clave retenida se pierde y el valor viejo se pisa |
| R18 | `ZSet.add` de un valor ya presente | 2 | El valor nuevo retenido se pierde |

Esto no es un bug de z-value en sentido estricto, porque la regla de ownership está documentada. Pero obliga a que todos los consumidores lo hagan bien siempre: `z-interpreter/LEAKS.md` documenta varias rondas de fugas de este tipo.

### P-API1 (A, en consumidores): crecer la unión rompe en silencio a los consumidores que usan `else`

- **z-toml** usa `isUnserializable` (`ztoml.zig:579-584`) con una lista de exclusión de 9 variantes que no se ha actualizado. `writeValue` termina en `else => unreachable` (`:707`). `stringify({x: 1n})` provoca **panic `reached unreachable code`** [medido]. También afecta, por inspección, a proxy, array_buffer, data_view, typed_array y temporal.
- **z-yaml** usa `isScalar` (`zyaml.zig:712-717`), que devuelve `true` para todo lo que no es array ni object. `writeScalar` termina en `else => unreachable` (`:708`). `stringify({m: new Map()})` provoca **panic** [medido]. Por inspección pasa lo mismo con set, regex, error, promise, bigint y los demás.
- **z-json** usa `switch` exhaustivo (`zjson.zig:207-288`) y no tiene este problema. Si se añade una variante, deja de compilar, que es el comportamiento correcto.

En ReleaseFast, esos `unreachable` son UB. La raíz está en z-value: hoy se añaden variantes (13 → 21 en los últimos meses, según `git log`) sin ninguna herramienta que ayude a los consumidores. No hay un predicado `isObjectLike()`, `isPrimitive()` o `isCallable()`, ni una clasificación por grupos.

### P-API2 (C): acoplamiento y huecos de la API

- **Cadena de dependencias de 15 repos por ruta relativa.** z-value importa el payload *completo* de cada z-*. Cualquier cambio de API en un hermano rompe z-value, y z-value no compila sin el árbol `../` completo.
- **`typeOf` decide por variante, no por capacidad.**
  - `.proxy` recurre sobre el target (`zvalue.zig:301`). Es correcto, pero no hay soporte de revocación: no existe estado "revocado" en `Proxy`, y z-interpreter no lo implementa [contado: 0 coincidencias de `revoke`].
- **`newDataView` y `newTypedArray` asumen que `owner` es `.array_buffer`** y acceden a `owner.array_buffer` sin comprobar el tag (`:249`, `:266`). En Debug provoca un panic de campo inactivo; en ReleaseFast es UB. El doc dice "asserts", pero no hay ningún `assert` explícito.
- **`DataViewBox` cachea un `zbuffer.DataView`** que apunta a `&owner.array_buffer.value` (`data_view_box.zig:17-18`), mientras que `TypedArrayBox` reconstruye la vista en cada acceso. Si z-buffer llega a soportar detach o resize, el DataView cacheado quedará obsoleto. Ver §4.
- **El hook de GC es por caja y se sobrescribe.** `setGcHook` no comprueba si ya había uno (`rc.zig:41-45`).
- **`cloneObject` devuelve `!JSValue`** (un error set inferido que incluye `ZObjectError`), mientras que el resto de `clone*` devuelve `ZValueError!JSValue`. Es una inconsistencia de API.

### P-DOC1 (C): documentación desincronizada

- `callable.zig:20-24` dice que `prototype` "is managed entirely by whoever installs the callable … never released here", y `:33` dice lo mismo de `statics`. Pero `Callable.deinit` (`:44-47`) **sí** los libera (cambiado en `84707d9`). Control CTRL [medido]: un `prototype` pasado a `newFunction` se libera sin fugas. El doc contradice al código.
- `zvalue.zig:48-50` y `rc.zig:4-7` describen la unión de 4 variantes con heap.
- `zvalue.zig:306-312` dice que Map/Set es el único consumidor de `eql`, lo cual es falso (ver P-EQ1).
- En `README.md`:
  - la tabla de variantes (`:40-58`) **no incluye `temporal`**;
  - la estructura de `src/` (`:88-100`) no incluye `temporal_value.zig`;
  - la lista "Non-invasive" (`:18`) no incluye z-temporal.

### P-TEST1 (C): faltan tests en zonas críticas [contado]

- **0** tests con `FailingAllocator`. Ningún camino de OOM está cubierto, y por eso R01–R12 pasaron desapercibidos.
- **0** tests que usen `indexOf`/`lastIndexOf` sobre `ZArray(JSValue)`, que es el lugar donde aparece P-EQ1.
- **0** tests de `setGcHook`.
- `cloneObject` solo se prueba con propiedades enumerables simples. No hay tests con accessors, no enumerables ni objetos congelados.
- No hay tests de mutación con reemplazo (`set` sobre una clave existente, `add` duplicado).
- No hay tests que comprueben que `strictEquals` y `sameValueZero` difieren justo donde deben (NaN), *pasando por* z-equality.

### P-ARCH1 (A, de diseño): no hay bolsa de propiedades ni lugar común para "esto es un objeto JS"

Está documentado en §1.5. Tiene tres consecuencias:
1. 8 de 11 tipos de objeto rechazan `x.p = v` [medido].
2. Cada consumidor inventa sus propias tablas laterales indexadas por puntero (4 en z-interpreter). Esas tablas deben mantenerse sincronizadas a mano con el GC: `interpreter_gc.zig` las recorre por separado.
3. No hay sitio para `[[Prototype]]` ni `[[Extensible]]` en los objetos exóticos. Su prototipo es implícito, se deduce del tag en el intérprete (`self.protos.map`, etc.), así que `Object.setPrototypeOf(new Map(), X)` no es representable.

---

## 3. Propuestas de mejora

### 3.1 Sin tocar la API (coste bajo, riesgo bajo)

| ID | Propuesta | Arregla | Coste [estimado] | Riesgo |
|---|---|---|---|---|
| F1 | Añadir `errdefer payload.deinit()` entre la construcción del payload y `Rc.create` en `newString`, `newSymbol`, `newError`, `newAggregateError`, `newBigInt`, `newArrayBuffer` y `newSharedArrayBuffer`. Incluye integrar `c5515bb`. | R01–R05 | ~15 líneas | Muy bajo |
| F2 | `errdefer` sobre lo recibido en `newProxy` (`target`, `handler`), `newAggregateError` (`errs`), `fromRegex` y `newBigIntFromValue`, para alinearlos con `newDataView`. Así la regla queda como "toma posesión **también si falla**". | R06, R07 | ~10 líneas | Bajo. Hay que confirmar que ningún consumidor libera lo que entregó cuando recibe un error (en z-interpreter, `gcNewProxy` no lo hace). |
| F3 | En los `clone*`: retener solo después de insertar con éxito (o liberar en `errdefer` los ya insertados), y añadir `errdefer` en `cloneError`. | R08–R12 | ~40 líneas | Bajo |
| F4 | Dar a `JSValue` un `eql` que **no** sea SameValueZero, para que el `strictEquals` genérico sea `===`. **Opción a:** que `JSValue.eql` llame a `equality.strictEquals`, y que Map/Set usen un contexto SameValueZero propio. Pero eso exige que z-map no dependa de `T.eql`; hoy usa `zequality.sameValueZero(K, …)`, que para uniones acaba en `T.eql`, así que también toca z-equality o z-map. **Opción b, solo en z-value:** documentar el problema y hacer que los consumidores (z-interpreter) no usen `ZArray.indexOf`/`lastIndexOf`/`count` con JSValue. | R13 | a: medio (toca z-equality); b: trivial | a: medio (cambia la semántica de todos los contenedores genéricos). b: no arregla nada. |
| F5 | `assert(owner == .array_buffer)` explícito en `newDataView` y `newTypedArray`. | P-API2 | 2 líneas | Nulo |
| F6 | Documentación: corregir `callable.zig:20-24, 33`, `zvalue.zig:48-50, 306-312`, `rc.zig:4-7` y el README (temporal); aclarar que `cloneObject` solo copia enumerables (o arreglarlo, F9); documentar que `Rc` no es thread-safe y que `setGcHook` sobrescribe. | P-DOC1 | Bajo | Nulo |
| F7 | Tests: incorporar R01–R18 (adaptados para que pasen tras F1–F3) más una prueba sistemática con `std.testing.checkAllAllocationFailures` para cada constructor y cada `clone*`; un test de `indexOf(NaN)`; tests de `setGcHook`. | P-TEST1 | ~300 líneas | Nulo |

### 3.2 Aditivos (API nueva sin romper nada; coste bajo-medio)

| ID | Propuesta | Arregla |
|---|---|---|
| A1 | Predicados de clasificación: `isPrimitive()`, `isObjectLike()`, `isCallable()` y `isContainer()`. Los consumidores con `else` (z-toml, z-yaml) los usarían en lugar de listas manuales de exclusión. Más un test en z-value que recorra `@typeInfo(JSValue).union.fields` y obligue a clasificar cada variante nueva, para que no se pueda añadir una sin decidir su grupo. | P-API1 (la causa raíz) |
| A2 | Mutadores conscientes de Rc: `objectSetOwned(key, v)`, que libera el valor viejo y el accessor sustituido; `mapSetOwned(k, v)`, que libera la clave duplicada y el valor viejo; `setAddOwned(v)`; `arrayPushOwned(v)`. | P-OWN4 (R15–R18) |
| A3 | `cloneObjectFull()`, o un parámetro, que copie descriptores, accessors (retenidos), no enumerables y flags. | P-SEM1 |

### 3.3 Con cambio de API (coste medio-alto)

Ver §3.4 para la bolsa de propiedades.

| ID | Cambio | Rompe |
|---|---|---|
| B1 | Añadir la bolsa de propiedades (§3.4, opción 1) | A quien nombra `Rc(X)` como tipo (z-interpreter: 20 usos [contado]) |
| B2 | `prototype` gestionado con refcount en la cabecera común (cierra el hueco del puntero crudo de ZObject) | z-object (`prototype: ?*Self`) y la cadena de búsqueda de z-interpreter |
| B3 | Claves de propiedad tipadas (`PropertyKey = union { string, symbol }`, con el símbolo retenido) en lugar de `"\x00S<ptr>"` | z-object o un tipo de bolsa nuevo en z-value; z-json, z-toml y z-yaml (filtro `key[0]==0`); z-interpreter |
| B4 | Reagrupar variantes (§3.5, opción 2) | Todos los consumidores |

### 3.4 Cómo debería ser la bolsa de propiedades

**Requisitos**, derivados de la semántica ECMAScript, sin asumir código del resto del ecosistema:
1. Cada valor con identidad de objeto puede tener propiedades propias con nombre: array, object, regex, map, set, error, function, date, promise, array_buffer, data_view, typed_array y temporal (13 variantes).
2. Los primitivos (string, symbol, bigint y los 4 inline) **no** tienen bolsa. Asignar sobre ellos es responsabilidad del intérprete, que lo ignora o lanza un error.
3. Proxy **no** tiene bolsa: todas las operaciones van al target o al handler.
4. La bolsa es perezosa: la inmensa mayoría de Maps, Dates, etc. no la necesitan nunca.
5. Comparte destino con `[[Prototype]]` y `[[Extensible]]`, que son los otros dos internal slots comunes a todo objeto ordinario.
6. Con ownership claro: `deinit` de la caja libera la bolsa, y el hook de GC del embedder tiene que poder recorrerla.

**Diseño recomendado (opción 1: cabecera común en la caja, sin reagrupar variantes).**

```zig
// rc.zig (o objbox.zig): cabecera opcional, solo para payloads de tipo objeto.
pub const ObjectHeader = struct {
    props: ?*Rc(ZObject(JSValue)) = null, // perezosa; 8 B
    // fase 2: proto: ?JSValue = null (null = el intrínseco por defecto del tag)
    // fase 2: extensible: bool = true
};

pub fn Rc(comptime T: type) type {
    return struct {
        count: usize,
        allocator: Allocator,
        value: T,
        header: if (isObjectLike(T)) ObjectHeader else void = ...,
        gc_hook_ctx: ..., gc_hook: ...,
    };
}
```

En `JSValue` se añade:
- `ownProps(self) ?*ZObject(JSValue)` devuelve `null` en primitivos, en proxy y cuando la bolsa aún no se ha creado. Para `.object` devuelve el propio payload.
- `ensureOwnProps(self, alloc) !*ZObject(JSValue)` crea la bolsa la primera vez. Para `.object` devuelve el payload; para primitivos, `error.NotAnObject`.
- `deinit`: un único bloque común, antes de `destroy()`, que libera `header.props` si existe, en lugar de 13 ramas distintas.
- `Callable.statics` se convierte en `header.props`, y se mantiene un alias deprecado durante una versión.

Qué gana el ecosistema:
- z-interpreter puede borrar `array_props` y la mitad de los casos `NotImplemented` de `setPropertyOnValue`. Su GC recorre un solo campo común en vez de 4 tablas laterales.
- `getOwnPropertyDescriptor` y `defineProperty` pasan a funcionar sobre cualquier objeto.
- Los consumidores que solo leen `box.value` siguen compilando sin cambios.

Coste:
- **+8 B por caja de objeto** [estimado a partir de los tamaños medidos: date 48→56 B (+17 %), map 96→104 B (+8 %), regex 840→848 B (+1 %)]. El efecto real depende de las clases de tamaño del allocator (ver §4).
- Rompe el código que construye cajas con `Rc(X).create` directamente o que nombra el tipo `Rc(X)`: 20 sitios en z-interpreter [contado], 0 en z-json, z-toml, z-yaml y z-run [contado].

**Alternativa de mínimo riesgo (opción 1b, sin tocar `Rc`).** Una tabla `PropBags` *dentro de z-value* (`AutoHashMap(*anyopaque, *Rc(ZObject(JSValue)))`), con `JSValue.ownProps(bags, v)`. Formaliza lo que hace hoy z-interpreter y es puramente aditiva. Pero sigue siendo una tabla lateral: hay que limpiarla cuando la caja muere (a través del hook de GC) y no resuelve `[[Prototype]]`. **Solo es recomendable como paso intermedio.**

**Claves símbolo (fase 2, B3).** La bolsa hereda la limitación de `ZObject` de usar claves de tipo string. Mientras siga así, los símbolos tendrán que codificarse como `"\x00S<ptr>"`. Lo correcto es un `PropertyKey` tipado con el símbolo retenido. Esto puede hacerse en z-object, en un `PropertyBag` propio de z-value, o dejarse como está; es una decisión pendiente (§5).

### 3.5 ¿Hay que reorganizar las variantes?

| | Opción 1: mantener 21 variantes + cabecera común | Opción 2: `object: *Rc(JSObject)` con `kind` interno |
|---|---|---|
| Forma | Igual que hoy. Cada caja de tipo objeto gana `header`. | ~8 tags: `undefined`, `null`, `boolean`, `number`, `string`, `symbol`, `bigint` y `object`. `JSObject { props, proto, extensible, kind: union { ordinary, array, map, set, error, function, date, promise, proxy, array_buffer, data_view, typed_array, temporal, regex } }` |
| Bolsa, proto y extensible | En la cabecera, en 13 tipos de caja | Un solo sitio |
| `typeOf`, `isObjectLike` | Un `switch` sobre 21 casos | Trivial |
| Igualdad e identidad | Igual que hoy | Una comparación de puntero para todos los objetos |
| Consumidores con `else` (P-API1) | Lo resuelve A1 | Desaparece estructuralmente: lo que hay que comprobar es `kind` |
| Rotura | Solo los usos de `Rc(X)` | **Total**: ~474 referencias a brazos en z-interpreter [contado], todos los `switch` de z-json, z-toml y z-yaml, y todos los `box.value` pasan a ser `box.value.kind.map` |
| Memoria | +8 B por objeto | `JSObject` = máx(payload) + cabecera. Si `kind` va inline, cada objeto paga el payload más grande, que es regex con 800 B, salvo que los payloads grandes vayan en otra indirección. [estimado; hay que medirlo] |
| Parecido con motores reales | — | V8/QuickJS (JSObject + class_id) |

**Recomendación:** la opción 1 ahora, porque desbloquea la bolsa con una rotura acotada a 20 sitios. La opción 2 solo tiene sentido si el ecosistema prevé seguir añadiendo tipos de objeto (WeakMap, WeakRef, Iterator helpers, Intl…). Cada tipo nuevo cuesta hoy unos 15 brazos nuevos en z-interpreter y uno en z-value, y A1 reduce el riesgo pero no ese coste. En cualquier caso, la opción 1 no cierra la puerta a la 2: la cabecera es exactamente el prefijo común que la opción 2 necesitaría.

### 3.6 Orden sugerido por coste y riesgo

1. **F1 + F2 + F3 + F5 + F7.** Son fixes de ownership con sus tests. No cambian la API y cierran R01–R12. [estimado: 1 PR pequeño]
2. **F6** (documentación) y **A1** (predicados de clasificación, más el test que obliga a clasificar cada variante). Después, un PR en z-toml y otro en z-yaml para usar A1, que cierran los panics.
3. **F4**: la corrección de `===` en contenedores genéricos (decidir entre la opción a y la b).
4. **A2 / A3**: mutadores y clon fiel.
5. **B1**: la bolsa de propiedades (opción 1). Requiere coordinarse con z-interpreter (los 20 sitios de `Rc(`, la migración de `Callable.statics` y `array_props`, y el recorrido del GC).
6. **B2 / B3**: prototipo con refcount y claves símbolo tipadas.
7. **B4**: solo si se decide la opción 2.

---

## 4. Lo que no se puede determinar sin medir

- **Coste real en memoria de la cabecera (+8 B):** depende de las clases de tamaño del allocator (el `gc_allocator` del embedder) y de cuántos objetos vivos hay por tipo en cargas reales. Habría que medir RSS y número de asignaciones con z-test262 o con benchmarks representativos, antes y después.
- **Cuántos objetos exóticos llegan a necesitar bolsa en la práctica:** decide si la bolsa perezosa basta o si conviene meterla inline. Habría que instrumentar `ensureOwnProps`.
- **Cuántos tests de Test262 desbloquearía la bolsa:** solo hay una inferencia por grep sobre `NotImplemented` en `setPropertyOnValue`. Habría que ejecutar z-test262 antes y después.
- **Colisión de claves `"\x00S<ptr>"` por reutilización de direcciones:** solo ocurre si el símbolo se libera mientras un objeto todavía tiene la propiedad. Depende de si el GC de z-interpreter mantiene vivos esos símbolos por otra vía. No se ha reproducido.
- **Comportamiento de `DataViewBox` ante detach o resize de un ArrayBuffer:** depende de si z-buffer lo soporta o lo soportará. No se ha revisado en profundidad.
- **Impacto de F4 opción a** (cambiar `JSValue.eql` a `===`) sobre otros contenedores genéricos del ecosistema que usen `T.eql` (z-promise, z-error, ¿otros?). Exige ejecutar las suites de todos los consumidores.
- **Rendimiento de la opción 2:** el `switch` sobre `kind` frente al tag, y la localidad de caché. No medido.
- **Si `cloneObject` está pensado para tener semántica `Object.assign`** (solo enumerables) o para ser una copia completa. Es una decisión de intención, no una cifra.
- **Fugas en ReleaseFast por underflow de `Rc`:** el assert desaparece en ese modo. No se ha probado ningún consumidor en ReleaseFast.

## 5. Decisiones pendientes (para el responsable)

1. ¿`newProxy` y `newAggregateError` deben consumir lo recibido también cuando fallan (F2)? Recomendado: sí, por coherencia con `newDataView`.
2. ¿P-EQ1 se arregla en z-value + z-equality (opción a) o en los consumidores (opción b)?
3. ¿La bolsa usa la opción 1 (cabecera en `Rc`) o la 1b (tabla en z-value) como paso intermedio?
4. ¿La bolsa debe soportar claves símbolo tipadas desde el principio (B3) o se mantiene `"\x00S<ptr>"`? Y si se tipan, ¿lo hace z-object o un `PropertyBag` propio de z-value?
5. ¿`[[Prototype]]` de los objetos exóticos entra en la cabecera (B2) en la misma versión que la bolsa?
6. ¿Se contempla la reagrupación de la opción 2, y en qué horizonte?

---

## Apéndice A: reproductores

Los proyectos están en el scratchpad de la sesión (`repro/`, `repro2/`), fuera del repo. Necesitan los repos hermanos en `/home/user/z-*`.

```
repro/repro.zig  (25 tests: 23 pass, 2 fail; 114 leaks)
R01 newString                       leaked 1     R10 cloneMap (OOM)            leaked 38
R02 newSymbol                       leaked 1     R11 cloneSet (OOM)            leaked 8
R03 newError                        leaked 1     R12 cloneError (OOM)          leaked 14
R04 newBigInt                       leaked 1     R13 indexOf(NaN)              FAILED expected null, found 0
R05 newArrayBuffer                  leaked 1     R14 cloneObject fidelity      FAILED 4/4 attributes lost
R06 newAggregateError               leaked 8     R15 ZObject.set over accessor leaked 1
R07 newProxy                        leaked 2     R16 ZObject.set overwrite     leaked 2
R08 cloneArray (OOM)                leaked 4     R17 ZMap.set dup key          leaked 4
R09 cloneObject (OOM)               leaked 26    R18 ZSet.add dup              leaked 2
CTRL (pasan): newDataView libera owner con OOM · strictEquals(NaN,NaN)=false ·
  includes(NaN)=true · Map: NaN con payloads distintos y ±0 colapsan ·
  Map: bigint por valor, string por contenido, object por identidad ·
  Callable.deinit libera prototype

repro2/  (z-toml, z-yaml)
z-toml stringify({x: 1n})        -> panic: reached unreachable code (ztoml.zig:707)
z-yaml stringify({m: new Map()}) -> panic: reached unreachable code (zyaml.zig:708)
```
