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

### 3. La versión 00 se bloquea al guardar Legales

Al guardar la cabecera de un proyecto nuevo se crea la versión 00 en `PENDIENTE`, pero **sin pausa**, para que puedan capturar Botella, Tapa, Etiqueta/Funda, Corrugado, Fórmula, Imagen y Legales. **Legales es el último apartado**: solo se puede guardar cuando lo demás está completo, y al guardarlo el proyecto pasa a `PAUSA` hasta que un administrador apruebe la versión 00. Las versiones siguientes se registran con TERMINAR y se pausan como siempre; para ellas Legales no exige nada.

**`ActualizaCabecera`**: la versión 00 se crea con `@Pausar = false` y ya no se llama `AplicarModoEdicion`:

```csharp
db.Database.ExecuteSqlCommand(
    "EXEC dnp_spGuardaVersion @Codigo, @usr, @cambio, @sCambio, @Pausar",
    new SqlParameter("@Codigo", codigoGenerado),
    new SqlParameter("@usr", Username),
    new SqlParameter("@cambio", "NUEVA"),
    new SqlParameter("@sCambio", false),
    new SqlParameter("@Pausar", false)   // se pausa al guardar Legales
);
...
lblProyectoCotiza.Text = codigoGenerado;
setTitle(codigoGenerado, txtprodCoti.Text);
```

**`ActualizaLegales`**: después de guardar, pausa si hay una versión pendiente:

```csharp
protected void ActualizaLegales(object sender, EventArgs e)
{
    if (EdicionBloqueada()) return;

    string usuario = UsuarioSesion();
    if (usuario == null) return;

    try
    {
        string reqLegal = radbtn_si.Checked ? "Y" : radbtn_no.Checked ? "N" : "";

        if (txtlegal.Text == "" || txtotrosobs.Text == "" || reqLegal == ""
            || (reqLegal == "Y" && txtEsp.Text == ""))
        {
            Page.ClientScript.RegisterStartupScript(this.GetType(), "Scripts", "<script>alert('Favor de llenar todos los datos.');</script>");
            return;
        }

        using (DNPEntities5 db = new DNPEntities5())
        {
            // Primera versión: Legales es el último apartado; antes debe estar capturado todo lo demás
            string faltantes = db.Database.SqlQuery<string>(
                "SELECT dbo.dnp_fnBriefFaltantesPrimeraVersion(@p)",
                new SqlParameter("@p", lblProyectoCotiza.Text)).FirstOrDefault();

            if (!string.IsNullOrEmpty(faltantes))
            {
                MostrarToast("Legales es el último apartado de la primera versión. Antes captura: " + faltantes + ".",
                             ToastTipo.Warning, "Brief incompleto");
                return;
            }

            db.sp_ActualizaLegalBrief(lblProyectoCotiza.Text, txtlegal.Text, txtotrosobs.Text, reqLegal, txtEsp.Text);

            // La versión 00 nace PENDIENTE al crear el proyecto; al completar Legales se bloquea
            db.Database.ExecuteSqlCommand(
                "EXEC dnp_spBriefPausarVersionPendiente @Proyecto, @Usuario",
                new SqlParameter("@Proyecto", lblProyectoCotiza.Text),
                new SqlParameter("@Usuario", usuario));
        }

        MostrarToast("Guardado Correctamente.", ToastTipo.Success);
        AplicarModoEdicion(lblProyectoCotiza.Text, true);
    }
    catch (Exception ex)
    {
        SqlException sqlEx = ex as SqlException ?? ex.InnerException as SqlException;
        string mensaje = (sqlEx != null && sqlEx.Number >= 50000)
            ? sqlEx.Message
            : "Error al actualizar legales.";
        MostrarToast(mensaje, ToastTipo.Error);
    }
}
```

`dnp_spGuardaVersion` ya no aprueba en automático la versión 00 (se quitó la línea `(*)`), el SP nuevo `dnp_spBriefPausarVersionPendiente` (sección 2b de `01_control_cambios_brief.sql`) aplica la pausa, y la función `dnp_fnBriefFaltantesPrimeraVersion` (sección 2a) dice qué falta. El SP vuelve a validarlo (error 50020), así que una versión 00 incompleta no se puede cerrar aunque se salte la validación de la pantalla.

## Pendientes fuera de este paquete

- **Credenciales escritas en el código** (LDAP y Report Server). Pásalas a `web.config` cifrado y cambia esa contraseña.
