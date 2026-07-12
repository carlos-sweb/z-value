# Z-Value

[![Versión de Zig](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org/)
[![Licencia: MIT](https://img.shields.io/badge/Licencia-MIT-blue.svg)](LICENSE)

**Z-Value** es un tipo `JSValue` de unión etiquetada con conteo de referencias, para el ecosistema de micro-librerías [z-*](https://github.com/carlos-sweb) escrito en Zig 0.16. Es la pieza que conecta las primitivas ECMAScript independientes y de tipado estático — [z-array](https://github.com/carlos-sweb/z-array), [z-object](https://github.com/carlos-sweb/z-object), [z-string](https://github.com/carlos-sweb/z-string), [zregexp](https://github.com/carlos-sweb/zregexp) — en algo que realmente puede representar un valor JS heterogéneo: una variable, un elemento de array, o una propiedad de objeto que puede ser un número hoy y un string mañana.

[🇬🇧 English Version](README.md)

## Por qué existe

`ZArray(T)` y `ZObject(T)` son genéricos pero **monomórficos** — un solo `T` fijo por instancia, como cualquier contenedor genérico en un lenguaje de tipado estático. Un array JS real (`[1, "a", true]`) es heterogéneo, algo que `ZArray(T)` solo no puede representar. `JSValue` es el `T` que hace que `ZArray(JSValue)` / `ZObject(JSValue)` se comporten como arrays/objetos JS reales — esto refleja cómo V8 y QuickJS comparten internamente una única representación de valor unificada (`Tagged<Object>` / `JSValue` respectivamente) entre `Array`, `Object`, `Number`, etc., en vez de mantener cada tipo completamente independiente.

## Diseño

- **Unión etiquetada, no NaN-boxing**: `undefined`/`null`/`boolean`/`number` van inline (bits trivialmente copiables); `string`/`array`/`object`/`regex` son heap-owning y viven detrás de un puntero a una caja con conteo de referencias.
- **Reference counting** (estilo QuickJS), no un tracing GC: predecible, sin pausas, pero **no** recolecta ciclos de referencias — ver [Limitaciones Conocidas](#limitaciones-conocidas).
- **No invasivo**: z-array/z-object/z-string/zregexp no saben nada de z-value. La caja `Rc(T)` en `src/rc.zig` los envuelve desde afuera; ninguno de esos proyectos tuvo que cambiar.

## Reglas de Ownership

Zig no tiene copy constructors ni destructores, así que esto es una **convención**, no algo que el compilador imponga:

- Copiar un `JSValue` por asignación **no** toca el contador de referencias.
- Llamá `.retain()` explícitamente cuando una copia necesite sobrevivir al binding original (ej. guardar el mismo valor en dos contenedores).
- Llamá `.deinit()` exactamente una vez por cada referencia retenida/propia. `deinit()` decrementa el contador y solo destruye el valor subyacente cuando llega a cero — el mismo hábito `defer value.deinit()` que ya se usa en toda la familia z-*, solo que ahora significa "libero *mi* referencia".
- **Nunca llames `ZArray(JSValue).clone()` ni los helpers de copia de propiedades de `ZObject(JSValue)` directamente.** Ambos son copias superficiales por bytes que no retienen sus elementos, así que dos "clones" terminarían compartiendo cajas con el contador sin incrementar → doble-free o liberación prematura. Usá `JSValue.cloneArray()` / `JSValue.cloneObject()` en su lugar, que retienen cada hijo correctamente.

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
| `regex` | ✅ Completo | `*Rc(Regex)` de zregexp, sin JSValues anidados que recorrer |

## Limitaciones Conocidas

- **`ZObject.prototype` no tiene conteo de referencias.** Es un `?*Self` crudo heredado de z-object sin gestión de lifetime propia — z-value no lo retiene ni lo libera. Si se libera un objeto prototipo mientras otro objeto todavía lo referencia, ese puntero queda colgante. Arreglar esto requeriría que z-object se vuelva consciente de Rc (o exponga un hook genérico de retain/release); fuera de alcance acá.
- **Los ciclos de referencias generan fugas.** Un array/objeto que (directa o indirectamente) contiene un `JSValue` que apunta de vuelta a sí mismo nunca llega a contador cero. No hay colector de ciclos en esta versión — romper los ciclos es responsabilidad del caller.
- **Se asume single-threaded.** `Rc(T).count` es un `usize` plano, no atómico. Un consumidor multi-hilo necesitaría atomics acá.
- **Un `retain()`/`deinit()` desbalanceado solo se detecta en Debug/ReleaseSafe.** `Rc.decref()` verifica con assert que el contador nunca haga underflow; en `ReleaseFast` ese assert se compila afuera y el underflow es comportamiento indefinido. Ejercitá siempre rutas nuevas de refcounting bajo `std.testing.allocator` en un build Debug primero.

## Instalación

Los repos hermanos se resuelven como paths locales en `build.zig.zon` (cambiar a `zig fetch --save git+...` cuando existan releases etiquetados):
```zig
.dependencies = .{
    .zarray = .{ .path = "../z-array" },
    .zobject = .{ .path = "../z-object" },
    .zregexp = .{ .path = "../zregexp" },
    .zstring = .{ .path = "../z-string" },
},
```

## Estructura del Proyecto

```
z-value/
├── src/
│   ├── zvalue.zig      # unión JSValue, constructores, retain()/deinit(), cloneArray()/cloneObject()
│   ├── rc.zig            # Caja genérica de conteo de referencias Rc(T)
│   ├── equality.zig      # strictEquals/sameValueZero/hash/JSValueHashContext
│   └── errors.zig
├── tests/
│   ├── value_types_test.zig
│   ├── rc_test.zig
│   ├── array_test.zig
│   ├── object_test.zig
│   ├── regex_test.zig
│   └── equality_test.zig
├── build.zig
└── build.zig.zon
```

## Correr los Tests

```bash
zig build test
```

## Licencia

MIT
