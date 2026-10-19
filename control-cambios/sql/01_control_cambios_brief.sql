/* =====================================================================================
   Control de cambios del Brief - correcciones
   Base: DNP

   Orden:
     0. dnp_spBriefCambiarEstatus  (sin cambios de lógica; incluido para desplegar en otra base)
     1. dnp_spBriefBloquear        (bloqueo del proyecto; ya creado, se deja idempotente)
     2. dnp_spGuardaVersion        (candado en BD, versión inicial pendiente, pausa obligatoria)
     2a. dnp_fnBriefFaltantesPrimeraVersion (secciones que faltan para cerrar la versión 00)
     2b. dnp_spBriefPausarVersionPendiente (pausa la versión 00 al guardar Legales)
     3. dnp_spBriefLiberarPausa    (error explícito si la pausa no está configurada)
     4. dnp_spObtenerAprobacion    (no ocultar versiones de usuarios fuera de dnp_Llenado)
     5. Verificación de configuración (solo lectura)
     6. Corrección de datos existentes (opcional, comentada)

   Requiere SQL Server 2016 SP1 o superior (CREATE OR ALTER, THROW).
   ===================================================================================== */
USE [DNP]
GO

/* -------------------------------------------------------------------------------------
   0. dnp_spBriefCambiarEstatus
   Único punto de cambio de estatus. Misma lógica que la versión en uso; se incluye
   para que una base nueva quede completa. Valida estatus destino activo (50002),
   asignación manual (50003), transición permitida (50004) y administrador (50005).
   Si lo llama otro SP dentro de su transacción (@@TRANCOUNT > 0), no abre la suya.
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [dbo].[dnp_spBriefCambiarEstatus]
    @Proyecto VARCHAR(20),
    @Destino  VARCHAR(20),
    @Usuario  VARCHAR(50),
    @Motivo   VARCHAR(200) = NULL,
    @Manual   BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @propia BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    DECLARE @origen VARCHAR(20), @reqAdmin BIT, @reinicia BIT, @manualOk BIT, @activo BIT;

    IF @propia = 1 BEGIN TRAN;

    SELECT @origen = OTRO
    FROM dbo.dnp_Cabecera_Brief WITH (UPDLOCK, ROWLOCK)
    WHERE NO_PROYECTO = @Proyecto;

    IF @@ROWCOUNT = 0
        THROW 50001, 'El proyecto no existe.', 1;

    IF @origen = @Destino
    BEGIN
        IF @propia = 1 COMMIT;
        RETURN;
    END

    SELECT @reinicia = REINICIA_FIRMAS, @manualOk = SELECCIONABLE_MANUAL, @activo = ACTIVO
    FROM dbo.dnp_Estatus_Brief
    WHERE ID_STATUS = @Destino;

    IF @activo IS NULL OR @activo = 0
        THROW 50002, 'El estatus destino no existe o está inactivo.', 1;

    IF @Manual = 1 AND @manualOk = 0
        THROW 50003, 'Ese estatus no se puede asignar manualmente.', 1;

    SELECT @reqAdmin = REQUIERE_ADMIN
    FROM dbo.dnp_Estatus_Brief_Transicion
    WHERE ORIGEN = @origen AND DESTINO = @Destino;

    IF @reqAdmin IS NULL
        THROW 50004, 'Cambio de estatus no permitido para el estado actual del proyecto.', 1;

    IF @reqAdmin = 1
       AND NOT EXISTS (SELECT 1 FROM dbo.dnp_Brief_Admin WHERE USUARIO = @Usuario)
        THROW 50005, 'Solo un Administrador puede realizar este cambio de estatus.', 1;

    UPDATE dbo.dnp_Cabecera_Brief
    SET OTRO = @Destino
    WHERE NO_PROYECTO = @Proyecto;

    IF @reinicia = 1
        UPDATE dbo.dnp_ProyectoBrief_Firma
        SET VENTAS = '', COSTOS = '', DESARROLLO = '', DIRECCION = '', VALIDACION = '',
            SYSTEM_DATE = GETDATE()
        WHERE NO_PROYECTO = @Proyecto;

    INSERT INTO dbo.dnp_Estatus_Brief_Historial
        (NO_PROYECTO, ESTATUS_ORIGEN, ESTATUS_DESTINO, USUARIO, MOTIVO, ORIGEN_ACCION)
    VALUES
        (@Proyecto, @origen, @Destino, @Usuario, @Motivo, CASE WHEN @Manual = 1 THEN 'MANUAL' ELSE 'SISTEMA' END);

    IF @propia = 1 COMMIT;
END
GO

/* -------------------------------------------------------------------------------------
   1. dnp_spBriefBloquear
   Toma el bloqueo de la fila del proyecto al inicio de la transacción que lo llama
   (aprobar, rechazar, TERMINAR). Todos los flujos bloquean primero la cabecera y
   después dnp_Brief_Version, así no se interbloquean entre sí.
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [dbo].[dnp_spBriefBloquear]
    @Proyecto VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @@TRANCOUNT = 0
        THROW 50040, 'dnp_spBriefBloquear debe ejecutarse dentro de una transacción.', 1;

    -- UPDLOCK se conserva hasta el COMMIT/ROLLBACK de la transacción que llama
    IF NOT EXISTS (SELECT 1
                   FROM dbo.dnp_Cabecera_Brief WITH (UPDLOCK, ROWLOCK)
                   WHERE NO_PROYECTO = @Proyecto)
        THROW 50001, 'El proyecto no existe.', 1;
END
GO

/* -------------------------------------------------------------------------------------
   2. dnp_spGuardaVersion
   Cambios respecto a la versión anterior:
     - Bloquea el proyecto antes de tocar dnp_Brief_Version (mismo orden que Aprobación).
     - El candado "una sola versión PENDIENTE" vive aquí, no solo en el C#.
     - La versión inicial (00) se crea al guardar la cabecera, PENDIENTE y sin pausa
       (@Pausar = 0); el proyecto se pausa al guardar Legales (sección 2b).
     - Si se pide pausar y no hay estatus de pausa válido, o la pausa no se aplica,
       se lanza un error y no se registra nada (antes fallaba en silencio).
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [dbo].[dnp_spGuardaVersion]
    @Codigo  AS VARCHAR(50),
    @usr     AS VARCHAR(50),
    @cambio  AS VARCHAR(MAX),
    @sCambio AS BIT,
    @Pausar  AS BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;   -- cualquier THROW revierte toda la transacción

    DECLARE @CONTADOR_NUM   INT = 0;
    DECLARE @VERSION_FORMAT VARCHAR(3);
    DECLARE @DESC           VARCHAR(MAX) = @cambio;
    DECLARE @pausa          VARCHAR(20);
    DECLARE @EstatusVersion VARCHAR(20) = 'PENDIENTE';

    BEGIN TRAN;

    EXEC dbo.dnp_spBriefBloquear @Proyecto = @Codigo;

    IF EXISTS (SELECT 1 FROM dbo.dnp_Brief_Version
               WHERE NO_PROYECTO = @Codigo AND Estatus = 'PENDIENTE')
        THROW 50010, 'Proyecto en espera de aprobación de DNP. No es posible registrar otro cambio hasta que se apruebe o rechace el cambio en curso.', 1;

    IF EXISTS (SELECT 1 FROM dbo.dnp_Brief_Version WHERE NO_PROYECTO = @Codigo)
    BEGIN
        SET @CONTADOR_NUM = (
            SELECT ISNULL(MAX(CAST([VERSION] AS INT)), -1)
            FROM dbo.dnp_Brief_Version
            WHERE NO_PROYECTO = @Codigo AND ISNUMERIC([VERSION]) = 1
        );

        IF @CONTADOR_NUM = -1
            SET @CONTADOR_NUM = 0;

        SET @CONTADOR_NUM = @CONTADOR_NUM + 1;
        SET @VERSION_FORMAT = RIGHT('00' + CAST(@CONTADOR_NUM AS VARCHAR(3)), 2);

        IF @sCambio = 1
            SET @DESC = 'Sin cambios / Revisión bienal';
    END
    ELSE
    BEGIN
        SET @VERSION_FORMAT = '00';
    END

    INSERT INTO dbo.dnp_Brief_Version (NO_PROYECTO, [Version], FechaAprob, Descripcion, Usuario, Estatus)
    VALUES (@Codigo, @VERSION_FORMAT, GETDATE(), @DESC, @usr, @EstatusVersion);

    IF @Pausar = 1
    BEGIN
        SELECT TOP 1 @pausa = ID_STATUS
        FROM dbo.dnp_Estatus_Brief
        WHERE ES_PAUSA = 1 AND ACTIVO = 1 AND PERMITE_EDICION = 0
        ORDER BY ORDEN;

        IF @pausa IS NULL
            THROW 50011, 'No hay un estatus de pausa activo (ES_PAUSA = 1, PERMITE_EDICION = 0) en dnp_Estatus_Brief.', 1;

        EXEC dbo.dnp_spBriefCambiarEstatus
             @Proyecto = @Codigo, @Destino = @pausa, @Usuario = @usr,
             @Motivo = 'Versión pendiente de validación', @Manual = 0;

        IF NOT EXISTS (SELECT 1 FROM dbo.dnp_Cabecera_Brief
                       WHERE NO_PROYECTO = @Codigo AND OTRO = @pausa)
            THROW 50012, 'No se pudo pausar el proyecto; el cambio no se registró.', 1;
    END

    COMMIT;
END
GO

/* -------------------------------------------------------------------------------------
   2a. dnp_fnBriefFaltantesPrimeraVersion
   Mientras la primera versión está abierta (versión PENDIENTE y proyecto sin pausa),
   devuelve las secciones que faltan por capturar, separadas por coma. Devuelve ''
   si no falta nada o si el proyecto no está en esa etapa (versiones posteriores).
   Se revisa un dato obligatorio de cada sección, así funciona aunque la fila exista
   vacía. Los proyectos SACHET no llevan Tapa. La Imagen es opcional (se puede
   capturar después).
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION [dbo].[dnp_fnBriefFaltantesPrimeraVersion]
(
    @Proyecto VARCHAR(20)
)
RETURNS VARCHAR(200)
AS
BEGIN
    DECLARE @f VARCHAR(200) = '', @forma VARCHAR(50);

    IF NOT EXISTS (SELECT 1 FROM dbo.dnp_Brief_Version
                   WHERE NO_PROYECTO = @Proyecto AND Estatus = 'PENDIENTE')
       OR EXISTS (SELECT 1
                  FROM dbo.dnp_Cabecera_Brief c
                  JOIN dbo.dnp_Estatus_Brief e ON e.ID_STATUS = c.OTRO
                  WHERE c.NO_PROYECTO = @Proyecto AND e.ES_PAUSA = 1)
        RETURN '';

    SELECT TOP 1 @forma = FORMA FROM dbo.dnp_Botella_Brief WHERE NO_PROYECTO = @Proyecto;

    IF ISNULL(@forma, '') = ''
        SET @f += ', Botella';
    IF @forma <> 'SACHET'
       AND NOT EXISTS (SELECT 1 FROM dbo.dnp_TapaBrief
                       WHERE NO_PROYECTO = @Proyecto AND ISNULL(TIPO, '') <> '')
        SET @f += ', Tapa';
    IF NOT EXISTS (SELECT 1 FROM dbo.dnp_FundaBrief
                   WHERE NO_PROYECTO = @Proyecto AND ISNULL(TIPO_MATERIAL, '') <> '')
        SET @f += ', Etiqueta/Funda';
    IF NOT EXISTS (SELECT 1 FROM dbo.dnp_CorrugadoBrief
                   WHERE NO_PROYECTO = @Proyecto AND ISNULL(MATERIAL, '') <> '')
        SET @f += ', Corrugado';
    IF NOT EXISTS (SELECT 1 FROM dbo.dnp_FormulaBrief
                   WHERE NO_PROYECTO = @Proyecto AND ISNULL(INGREDIENTES, '') <> '')
        SET @f += ', Fórmula';

    RETURN CASE WHEN @f = '' THEN '' ELSE STUFF(@f, 1, 2, '') END;
END
GO

/* -------------------------------------------------------------------------------------
   2b. dnp_spBriefPausarVersionPendiente
   La versión 00 nace PENDIENTE al guardar la cabecera, pero el proyecto sigue editable
   para que llenen el Brief. Al guardar Legales, Brief llama este SP: si hay una versión
   PENDIENTE y el proyecto aún no está en pausa, lo pausa hasta que se apruebe.
   Antes valida que la primera versión esté completa (error 50020 con lo que falta).
   Si no hay nada pendiente o ya está en pausa, no hace nada.
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [dbo].[dnp_spBriefPausarVersionPendiente]
    @Proyecto VARCHAR(20),
    @Usuario  VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @propia BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    DECLARE @pausa VARCHAR(20), @falta VARCHAR(200), @msg NVARCHAR(400);

    IF @propia = 1 BEGIN TRAN;

    EXEC dbo.dnp_spBriefBloquear @Proyecto = @Proyecto;

    IF EXISTS (SELECT 1 FROM dbo.dnp_Brief_Version
               WHERE NO_PROYECTO = @Proyecto AND Estatus = 'PENDIENTE')
       AND NOT EXISTS (SELECT 1
                       FROM dbo.dnp_Cabecera_Brief c
                       JOIN dbo.dnp_Estatus_Brief e ON e.ID_STATUS = c.OTRO
                       WHERE c.NO_PROYECTO = @Proyecto AND e.ES_PAUSA = 1)
    BEGIN
        SET @falta = dbo.dnp_fnBriefFaltantesPrimeraVersion(@Proyecto);
        IF @falta <> ''
        BEGIN
            SET @msg = N'Para cerrar la primera versión falta capturar: ' + @falta + N'.';
            THROW 50020, @msg, 1;
        END

        SELECT TOP 1 @pausa = ID_STATUS
        FROM dbo.dnp_Estatus_Brief
        WHERE ES_PAUSA = 1 AND ACTIVO = 1 AND PERMITE_EDICION = 0
        ORDER BY ORDEN;

        IF @pausa IS NULL
            THROW 50011, 'No hay un estatus de pausa activo (ES_PAUSA = 1, PERMITE_EDICION = 0) en dnp_Estatus_Brief.', 1;

        EXEC dbo.dnp_spBriefCambiarEstatus
             @Proyecto = @Proyecto, @Destino = @pausa, @Usuario = @Usuario,
             @Motivo = 'Versión pendiente de validación', @Manual = 0;
    END

    IF @propia = 1 COMMIT;
END
GO

/* -------------------------------------------------------------------------------------
   3. dnp_spBriefLiberarPausa
   Distingue "no está en pausa" (sale sin error, p. ej. versión 00) de
   "está en pausa pero sin ESTATUS_AL_LIBERAR" (error: antes aprobaba la versión
   y dejaba el proyecto en pausa para siempre).
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [dbo].[dnp_spBriefLiberarPausa]
    @Proyecto VARCHAR(20),
    @Usuario  VARCHAR(50),
    @Motivo   VARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @esPausa BIT, @liberar VARCHAR(20);

    SELECT @esPausa = ISNULL(e.ES_PAUSA, 0),
           @liberar = e.ESTATUS_AL_LIBERAR
    FROM dbo.dnp_Cabecera_Brief c
    LEFT JOIN dbo.dnp_Estatus_Brief e ON e.ID_STATUS = c.OTRO
    WHERE c.NO_PROYECTO = @Proyecto;

    IF ISNULL(@esPausa, 0) = 0
        RETURN;                                   -- no está en pausa

    IF @liberar IS NULL
        THROW 50030, 'El estatus de pausa no tiene ESTATUS_AL_LIBERAR configurado; no se puede liberar el proyecto.', 1;

    IF EXISTS (SELECT 1 FROM dbo.dnp_Brief_Version
               WHERE NO_PROYECTO = @Proyecto AND ESTATUS = 'PENDIENTE')
        RETURN;                                   -- aún quedan cambios por validar

    EXEC dbo.dnp_spBriefCambiarEstatus
         @Proyecto = @Proyecto, @Destino = @liberar, @Usuario = @Usuario,
         @Motivo = @Motivo, @Manual = 0;
END
GO

/* -------------------------------------------------------------------------------------
   4. dnp_spObtenerAprobacion
   LEFT JOIN a dnp_Llenado: antes, la versión de un usuario que no estuviera en esa
   tabla no aparecía en Aprobaciones y el proyecto se quedaba en pausa sin poder
   aprobarse. @busqueda se amplía a 100 caracteres.
   ------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE [dbo].[dnp_spObtenerAprobacion]
    @busqueda AS VARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        T1.NO_PROYECTO AS PROYECTO,
        T1.PRODUCTO    AS PRODUCTO,
        T2.VERSION,
        T2.ESTATUS,
        ISNULL(T3.USUARIO, T2.USUARIO) AS USUARIO
    FROM dbo.dnp_Cabecera_Brief AS T1
    INNER JOIN dbo.dnp_Brief_Version AS T2 ON T1.NO_PROYECTO = T2.NO_PROYECTO
    LEFT  JOIN dbo.dnp_Llenado      AS T3 ON T2.USUARIO = T3.Usuario
    LEFT  JOIN dbo.dnp_Clientes     AS T4 ON T1.ID_CLIENTE = T4.ID_CLIENTE
    WHERE
        T2.ESTATUS = 'PENDIENTE'
        AND (
            @busqueda = 'PROYECTO'
            OR T1.NO_PROYECTO LIKE '%' + @busqueda + '%'
            OR T1.PRODUCTO    LIKE '%' + @busqueda + '%'
            OR T4.NOMBRE      LIKE '%' + @busqueda + '%'
        )
    ORDER BY T1.NO_PROYECTO;
END
GO

/* -------------------------------------------------------------------------------------
   5. Verificación de configuración (solo lectura). Cada consulta debería regresar
      lo indicado en su comentario.
   ------------------------------------------------------------------------------------- */

-- 5a. Exactamente un estatus de pausa activo, con PERMITE_EDICION = 0 y ESTATUS_AL_LIBERAR activo.
SELECT p.ID_STATUS AS Pausa, p.PERMITE_EDICION, p.ESTATUS_AL_LIBERAR,
       d.ACTIVO AS DestinoActivo,
       t.REQUIERE_ADMIN AS TransicionLiberar      -- NULL = falta la transición PAUSA -> destino
FROM dbo.dnp_Estatus_Brief p
LEFT JOIN dbo.dnp_Estatus_Brief d            ON d.ID_STATUS = p.ESTATUS_AL_LIBERAR
LEFT JOIN dbo.dnp_Estatus_Brief_Transicion t ON t.ORIGEN = p.ID_STATUS AND t.DESTINO = p.ESTATUS_AL_LIBERAR
WHERE p.ES_PAUSA = 1 AND p.ACTIVO = 1;

-- 5b. Debe regresar VACÍO: estatus editables desde los que TERMINAR no podría pausar (error 50004).
SELECT e.ID_STATUS AS SinTransicionAPausa
FROM dbo.dnp_Estatus_Brief e
WHERE e.ACTIVO = 1 AND e.PERMITE_EDICION = 1 AND ISNULL(e.ES_PAUSA, 0) = 0
  AND NOT EXISTS (SELECT 1
                  FROM dbo.dnp_Estatus_Brief_Transicion t
                  JOIN dbo.dnp_Estatus_Brief p ON p.ID_STATUS = t.DESTINO AND p.ES_PAUSA = 1 AND p.ACTIVO = 1
                  WHERE t.ORIGEN = e.ID_STATUS);

-- 5c. Debe regresar VACÍO: objetos que usa el control de cambios y no existen.
SELECT Tipo, Nombre AS ObjetoFaltante
FROM (VALUES
    ('P','dnp_spBriefBloquear'), ('P','dnp_spBriefLiberarPausa'), ('P','dnp_spBriefPausarVersionPendiente'), ('FN','dnp_fnBriefFaltantesPrimeraVersion'), ('P','dnp_spBriefCambiarEstatus'),
    ('P','dnp_spGuardaVersion'), ('P','dnp_spObtenerAprobacion'), ('P','sp_FiltraAprobaciones'),
    ('U','dnp_Estatus_Brief'), ('U','dnp_Estatus_Brief_Transicion'),
    ('U','dnp_Estatus_Brief_Historial'), ('U','dnp_Brief_Admin')
) AS x(Tipo, Nombre)
WHERE OBJECT_ID('dbo.' + Nombre, Tipo) IS NULL;

-- 5d. Debe regresar VACÍO: proyectos en pausa sin versión pendiente (atorados).
SELECT c.NO_PROYECTO, c.OTRO
FROM dbo.dnp_Cabecera_Brief c
JOIN dbo.dnp_Estatus_Brief e ON e.ID_STATUS = c.OTRO AND e.ES_PAUSA = 1
WHERE NOT EXISTS (SELECT 1 FROM dbo.dnp_Brief_Version v
                  WHERE v.NO_PROYECTO = c.NO_PROYECTO AND v.ESTATUS = 'PENDIENTE');
GO

/* -------------------------------------------------------------------------------------
   6. (OPCIONAL, una sola vez) Versiones iniciales que quedaron PENDIENTE en proyectos
      que NO están en pausa. Con el SP nuevo ya no se generan; estas son las anteriores
      y bloquean el primer TERMINAR. Revisa el SELECT y, si estás de acuerdo,
      descomenta el UPDATE.
   ------------------------------------------------------------------------------------- */
SELECT v.id_version, v.NO_PROYECTO, v.[VERSION], v.ESTATUS, v.USUARIO, c.OTRO AS EstatusProyecto
FROM dbo.dnp_Brief_Version v
JOIN dbo.dnp_Cabecera_Brief c ON c.NO_PROYECTO = v.NO_PROYECTO
LEFT JOIN dbo.dnp_Estatus_Brief e ON e.ID_STATUS = c.OTRO
WHERE v.ESTATUS = 'PENDIENTE'
  AND CAST(v.[VERSION] AS VARCHAR(10)) IN ('0', '00')
  AND ISNULL(e.ES_PAUSA, 0) = 0;

/*
UPDATE v
SET v.ESTATUS = 'APROBADO',
    v.USUARIO_APROBACION = 'SISTEMA',
    v.MOTIVO = 'Versión inicial aprobada automáticamente'
FROM dbo.dnp_Brief_Version v
JOIN dbo.dnp_Cabecera_Brief c ON c.NO_PROYECTO = v.NO_PROYECTO
LEFT JOIN dbo.dnp_Estatus_Brief e ON e.ID_STATUS = c.OTRO
WHERE v.ESTATUS = 'PENDIENTE'
  AND CAST(v.[VERSION] AS VARCHAR(10)) IN ('0', '00')
  AND ISNULL(e.ES_PAUSA, 0) = 0;
*/
GO
