# Prueba del flujo completo del control de cambios

## Antes de empezar

- Aplicados `sql/01_control_cambios_brief.sql` y `sql/02_datos_estatus_brief.sql`.
- Reemplazado `Aprobacion.aspx.cs` y aplicados en `Brief.aspx.cs` los cambios 1, 2 y 3 del README.
- Dos usuarios:
  - **Capturista**: no está en `dnp_Brief_Admin`.
  - **Administrador**: está en `dnp_Brief_Admin` (BTOLEDANO, DRAMIREZ o JALVAREZ).
- Usa dos navegadores, o uno normal y otro en modo incógnito, para tener las dos sesiones abiertas.

Deja abierta en SSMS esta consulta y córrela después de cada paso (cambia `XXXX` por el código del proyecto de prueba):

```sql
DECLARE @p VARCHAR(20) = 'XXXX';

SELECT NO_PROYECTO, OTRO AS Estatus FROM dnp_Cabecera_Brief WHERE NO_PROYECTO = @p;

SELECT id_version, [VERSION], ESTATUS, USUARIO, USUARIO_APROBACION, MOTIVO
FROM dnp_Brief_Version WHERE NO_PROYECTO = @p ORDER BY id_version;

SELECT * FROM dnp_Estatus_Brief_Historial WHERE NO_PROYECTO = @p ORDER BY 1;
```

## Pasos

| # | Quién / dónde | Acción | Resultado esperado en pantalla | En la BD |
|---|---|---|---|---|
| 1 | Capturista, Brief | Crear proyecto: llenar la cabecera y guardar | "Guardado Correctamente"; aparece el código del proyecto; **sigue editable** | Versión `00` `PENDIENTE` (descripción `NUEVA`); `Estatus = NUEVO` |
| 2 | Capturista, Brief | Guardar **Legales** antes de llenar lo demás | "Legales es el último apartado de la primera versión. Antes captura: Botella, Tapa, Etiqueta/Funda, Corrugado, Fórmula, Imagen."; **no** se guarda | Sin cambios |
| 3 | Capturista, Brief | Llenar y guardar Botella, Tapa, Etiqueta/Funda, Corrugado, Fórmula e Imagen; después guardar **Legales** | "Guardado Correctamente"; se abre el aviso "Proyecto en pausa"; aparece el chip; los controles quedan deshabilitados | `Estatus = PAUSA`; historial `NUEVO → PAUSA` (`SISTEMA`) |
| 4 | Capturista, Brief | Recorrer todas las secciones, incluida **Fórmula** | Todo sigue deshabilitado, también en Fórmula | Sin cambios |
| 5 | Capturista, Brief | Entrar a Firmas | "Acceso denegado. El proyecto no está en un estatus que permita firmar." | Sin cambios |
| 6 | Capturista, Brief | Intentar TERMINAR otra vez (si el botón está habilitado) | "Candado de aprobación" | Sigue habiendo **una sola** versión `PENDIENTE` |
| 7 | Capturista, Aprobaciones | Seleccionar la versión 00 y presionar Aprobar con comentario | "Acceso denegado. No tiene permiso para aprobar esta versión." | Sin cambios |
| 8 | Administrador, Aprobaciones | Seleccionar la versión 00 y presionar Aprobar **sin** comentario | "Debe ingresar un comentario…" | Sin cambios |
| 9 | Administrador, Aprobaciones | Escribir un comentario y presionar Aprobar | "La versión ha sido aprobada correctamente."; la versión desaparece de la lista | Versión `00` `APROBADO`, con usuario y motivo; `Estatus = NUEVO`; historial `PAUSA → NUEVO` (`SISTEMA`) |
| 10 | Capturista, Brief | **Volver a seleccionar** el proyecto en la lista | Ya no aparecen el chip ni el aviso; todo es editable. Llenar y guardar Botella, Tapa, Funda, Corrugado, Fórmula y Legales | Sin cambios |
| 11 | Capturista, Brief | Cambiar un dato, guardar y hacer TERMINAR con justificación | Pausa otra vez, igual que en el paso 3 | Versión `01` `PENDIENTE`; `Estatus = PAUSA` |
| 12 | Administrador, Aprobaciones | Rechazar la versión 01 con comentario | "La versión ha sido rechazada correctamente." | Versión `01` `RECHAZADO`; `Estatus = NUEVO` |
| 13 | Capturista, Brief | Volver a seleccionar el proyecto | Editable. El dato cambiado en el paso 11 **se queda**: rechazar no deshace los cambios guardados | Sin cambios |

En el paso 10, la pantalla de Brief que ya estaba abierta no se entera de la aprobación hecha en otra página. Hay que volver a seleccionar el proyecto (o recargar la página) para que se quite el bloqueo.

## Prueba opcional: dos administradores a la vez

Con una versión `PENDIENTE`, abre Aprobaciones con dos administradores, selecciona la misma versión en ambos y aprueba en los dos casi al mismo tiempo. El primero debe ver "aprobada correctamente". El segundo debe ver "No se encontró la versión … en estatus PENDIENTE". En la BD debe quedar un solo cambio de estatus en el historial.

## Si aparece un error

Con los cambios aplicados, los errores de los SP llegan a la pantalla con su mensaje:

| Mensaje | Causa | Qué revisar |
|---|---|---|
| "El proyecto no existe." (50001) | Se hizo TERMINAR sin haber guardado la cabecera | Guardar la cabecera primero |
| "El estatus destino no existe o está inactivo." (50002) | `PAUSA` o `NUEVO` falta o está inactivo | `SELECT * FROM dnp_Estatus_Brief` |
| "Cambio de estatus no permitido…" (50004) | Falta la transición `estatus actual → PAUSA` o `PAUSA → NUEVO` | `dnp_Estatus_Brief_Transicion`; volver a correr `02_datos_estatus_brief.sql` |
| "Solo un Administrador…" (50005) | El usuario no está en `dnp_Brief_Admin` | Comparar `Session["User"]` con `SELECT * FROM dnp_Brief_Admin` |
| "No hay un estatus de pausa activo…" (50011) | No hay ningún estatus con `ES_PAUSA = 1` y `PERMITE_EDICION = 0` | La fila de `PAUSA` |
| "El estatus de pausa no tiene ESTATUS_AL_LIBERAR…" (50030) | `PAUSA` sin destino al liberar | `UPDATE dnp_Estatus_Brief SET ESTATUS_AL_LIBERAR = 'NUEVO' WHERE ID_STATUS = 'PAUSA'` |
| "Error al procesar la versión: …" | Error no previsto (objeto faltante, columna, permisos) | El texto después de los dos puntos; correr la consulta 5c de `01_control_cambios_brief.sql` |
