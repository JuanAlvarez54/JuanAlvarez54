# Control de cambios del Brief: correcciones

## Contenido

| Archivo | Qué hace |
|---|---|
| `sql/00_tablas_control_cambios_brief.sql` | Tablas del control de cambios (idempotente) y exportación de su configuración |
| `sql/02_datos_estatus_brief.sql` | Datos iniciales del catálogo de estatus y transiciones (si están vacíos) |
| `sql/01_control_cambios_brief.sql` | SP corregidos, verificación de configuración y corrección opcional de datos |
| `csharp/Brief_campos_static.md` | Quitar los campos `static` y `req_legal` de Brief.aspx.cs |
| `PRUEBAS.md` | Guion de prueba del flujo completo |
| `csharp/Aprobacion.aspx.cs` | Reemplazo completo de la página de Aprobaciones |
| Este README, sección "Brief.aspx.cs" | Dos cambios puntuales en Brief |

## Orden de aplicación

1. **Respaldo** de los SP actuales: en SSMS, clic derecho en el SP → *Incluir procedimiento como* → *ALTER en*.
2. **Solo en una base nueva** (p. ej. producción): ejecutar `sql/00_tablas_control_cambios_brief.sql` y después los INSERT que genera su sección de exportación (corrida en la base que ya funciona). En la base donde ya funciona no hace falta: el script no toca tablas existentes.
3. Ejecutar `sql/01_control_cambios_brief.sql` (secciones 0 a 4; la 0 es `dnp_spBriefCambiarEstatus` sin cambios de lógica).
4. Revisar los resultados de la **sección 5**. 5b, 5c y 5d deben salir vacías, y 5a debe mostrar un estatus de pausa con `ESTATUS_AL_LIBERAR`, `DestinoActivo = 1` y `TransicionLiberar` distinto de NULL.
5. Decidir la **sección 6** (versiones iniciales PENDIENTE que ya existen) y, si aplica, descomentar el UPDATE.
6. Reemplazar `Aprobacion.aspx.cs` y aplicar los cambios de `Brief.aspx.cs` (abajo).
7. Probar el flujo: crear proyecto → TERMINAR con cambio → (en pausa) entrar a Fórmula → aprobar → repetir con rechazar.

## Qué cambia

### SQL
- **`dnp_spGuardaVersion`**
  - Bloquea el proyecto con `dnp_spBriefBloquear`, en el mismo orden que la aprobación, para evitar interbloqueos.
  - El candado de "una sola versión PENDIENTE" ahora vive en la BD (error 50010).
  - **La versión inicial (00) sin pausa nace `APROBADO`**, así ya no bloquea el primer TERMINAR. Si la versión inicial sí debe validarse, quita la línea marcada `(*)`.
  - Si no hay estatus de pausa válido (50011) o la pausa no se aplica (50012), no registra nada. Antes fallaba en silencio.
- **`dnp_spBriefLiberarPausa`**: si el proyecto está en pausa pero sin `ESTATUS_AL_LIBERAR`, lanza el error 50030. Antes aprobaba la versión y dejaba el proyecto en pausa para siempre.
- **`dnp_spObtenerAprobacion`**: `LEFT JOIN` a `dnp_Llenado`. Antes, la versión de un usuario que no estuviera en esa tabla no aparecía para aprobarse.

### Aprobacion.aspx.cs
- Aprobar y rechazar comparten una sola rutina (`ResolverVersion`), que devuelve si se confirmó. Antes el aviso de éxito salía aunque hubiera fallado.
- Muestra el **error real**. Los mensajes de negocio (≥ 50000) salen tal cual; cualquier otro error sale con detalle, que fue lo que escondió el SP faltante.
- Los permisos se validan contra `dnp_Brief_Admin`, igual que los SP, en lugar del arreglo fijo de usuarios.
- Los avisos usan una clave única y texto escapado (`Toast`), así ya no se tapan entre sí ni rompen el JavaScript.
- Los valores de la grilla se limpian (`&nbsp;`, espacios) antes de compararlos.
- Se eliminan `EjecutarAprobacion`, `EjecutarRechazo`, `FinalizarAprobacionExitosa`, `FinalizarRechazoExitoso`, `_errorNegocio` y `ApruebaVersion()`, que era código viejo sin uso y con otra lista de usuarios.

> Verifica en el `.aspx` que la grilla tenga primero la columna del botón Seleccionar (el código lee `Cells[1]` = proyecto y `Cells[3]` = versión) y que esté ligada con `OnItemCommand="DataGrid1_ItemCommand"`.

## Brief.aspx.cs

### 1. No re-habilitar controles al entrar a Fórmula (menú 6)

Agrega este método junto a `AplicarModoEdicion`:

```csharp
// La configuración por tipo de proyecto habilita controles de Fórmula; si el proyecto
// está en pausa se vuelven a bloquear antes de mostrar la vista.
private void MostrarVistaFormula()
{
    AplicarModoEdicion(lblProyectoCotiza.Text);
    MultiView1.ActiveViewIndex = 6;
}
```

En `Menu3_MenuItemClick`, dentro de `else if (value == "6")`, reemplaza las **tres** líneas

```csharp
MultiView1.ActiveViewIndex = 6;
```

por

```csharp
MostrarVistaFormula();
```

(una en la rama GEL/CERA/CREMAS, otra en BLOQUEADOR y otra en SHAMPOO).

### 2. Mostrar los errores de TERMINAR

`dnp_spGuardaVersion` ahora lanza mensajes de negocio (50010, 50011, 50012 y 50004 desde `dnp_spBriefCambiarEstatus`). En `btnGuardarCambios_Click`, reemplaza el `catch` por:

```csharp
catch (Exception ex)
{
    // Los errores >= 50000 de los SP son mensajes de negocio pensados para el usuario.
    SqlException sqlEx = ex as SqlException ?? ex.InnerException as SqlException;
    string mensaje = (sqlEx != null && sqlEx.Number >= 50000)
        ? sqlEx.Message
        : "Error al registrar el cambio.";
    MostrarToast(mensaje, ToastTipo.Error);
}
```

### 3. La versión 00 también se bloquea (al primer TERMINAR)

Hoy `ActualizaCabecera` crea la versión 00 en cuanto se guarda la cabecera, sin pausar. Con este cambio, la cabecera ya no crea versión. La versión 00 nace en el **primer TERMINAR**, igual que las demás: queda `PENDIENTE`, el proyecto pasa a `PAUSA` y se bloquea hasta que un administrador la apruebe. Así el usuario puede llenar todas las secciones del Brief antes de mandarlo a validación.

En `ActualizaCabecera`, reemplaza desde `string Username = ...` hasta la recarga del grid (`clIdent.CargarDataGrid(...)` en el `if/else`) por:

```csharp
string tipo_proyecto = DropTP.SelectedValue;

// Guardar si es proyecto nuevo (antes de actualizar)
bool esProyectoNuevo = (lblProyectoCotiza.Text == "NUEVO");

db.sp_ActualizaCabeceraBrief(lblProyectoCotiza.Text, Convert.ToInt32(dpSolicitaCoti.SelectedValue), txtprodCoti.Text, Convert.ToInt32(txtcajasCoti.Text), tipoMaquila, "NUEVO", tipo_proyecto);

// La versión 00 ya no se crea aquí: nace en el primer TERMINAR y deja el proyecto en PAUSA.
if (esProyectoNuevo)
{
    string codigoGenerado = db.Database.SqlQuery<string>(
        @"SELECT TOP 1 NO_PROYECTO
          FROM dnp_Cabecera_Brief
          WHERE PRODUCTO = @proyecto
          AND ID_CLIENTE = @Cliente
          AND TIPO_MAQUILA = @tipoMaq
          AND NO_PROYECTO <> 'NUEVO'
          ORDER BY SYSTEM_DATE DESC",
        new SqlParameter("@proyecto", txtprodCoti.Text),
        new SqlParameter("@Cliente", Convert.ToInt32(dpSolicitaCoti.SelectedValue)),
        new SqlParameter("@tipoMaq", tipoMaquila)
    ).FirstOrDefault();

    if (!string.IsNullOrEmpty(codigoGenerado))
        lblProyectoCotiza.Text = codigoGenerado;
}

clIdent.CargarDataGrid(ref dgVersionDNP, lblProyectoCotiza.Text, "dnp_spObtenerVersionesPerfil");
```

Este reemplazo corrige además otro error: antes, al editar la cabecera de un proyecto existente, el grid de versiones se recargaba con el **último proyecto del mismo producto, cliente y maquila**, que podía ser otro proyecto.

`dnp_spGuardaVersion` no necesita cambios: el C# de TERMINAR ya manda `@Pausar = 1`, y con eso la versión 00 queda `PENDIENTE`. La línea `(*)` del SP solo aplicaba a la versión creada desde la cabecera. Puedes dejarla o quitarla.

> Alternativa, si quieres que se bloquee desde que se guarda la cabecera: no apliques este cambio. En su lugar, agrega `new SqlParameter("@Pausar", true)` (y `@Pausar` al `EXEC`) en la creación de la versión 00 de `ActualizaCabecera`. El inconveniente es que el usuario no podrá llenar Botella, Tapa, Fórmula, etc. hasta que se apruebe.

## Pendientes fuera de este paquete

- **Credenciales escritas en el código** (LDAP y Report Server). Pásalas a `web.config` cifrado y cambia esa contraseña.
