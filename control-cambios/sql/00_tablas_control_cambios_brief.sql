/* =====================================================================================
   Control de cambios del Brief - tablas
   Base: DNP

   IMPORTANTE: estas definiciones se reconstruyeron a partir de las columnas que usan
   los SP y el C# (dnp_spBriefCambiarEstatus, dnp_spGuardaVersion, dnp_spBriefLiberarPausa,
   Brief.aspx.cs, Aprobacion.aspx.cs). Si las tablas ya existen en otra base, la copia
   exacta es la del paso B (SSMS > Generar scripts) o la exportación de la sección 4.

   Es idempotente: solo crea lo que no existe; no modifica ni borra tablas existentes.

   Orden de despliegue en una base nueva:
     1. Este script (tablas y columnas)
     2. Datos de configuración (sección 4, generados desde la base que ya funciona)
     3. 01_control_cambios_brief.sql (todos los SP, incluido dnp_spBriefCambiarEstatus)
   ===================================================================================== */
USE [DNP]
GO

/* -------------------------------------------------------------------------------------
   1. dnp_Estatus_Brief: catálogo de estatus y sus reglas
   ------------------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.dnp_Estatus_Brief', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dnp_Estatus_Brief
    (
        ID_STATUS            VARCHAR(20)   NOT NULL,
        ORDEN                INT           NOT NULL CONSTRAINT DF_dnp_Estatus_Brief_ORDEN DEFAULT (0),
        ACTIVO               BIT           NOT NULL CONSTRAINT DF_dnp_Estatus_Brief_ACTIVO DEFAULT (1),
        VISIBLE_EN_LISTA     BIT           NOT NULL CONSTRAINT DF_dnp_Estatus_Brief_VISIBLE DEFAULT (1),
        SELECCIONABLE_MANUAL BIT           NOT NULL CONSTRAINT DF_dnp_Estatus_Brief_MANUAL DEFAULT (1),
        PERMITE_EDICION      BIT           NOT NULL CONSTRAINT DF_dnp_Estatus_Brief_EDICION DEFAULT (1),
        PERMITE_FIRMA        BIT           NOT NULL CONSTRAINT DF_dnp_Estatus_Brief_FIRMA DEFAULT (0),
        REINICIA_FIRMAS      BIT           NOT NULL CONSTRAINT DF_dnp_Estatus_Brief_REINICIA DEFAULT (0),
        ES_PAUSA             BIT           NOT NULL CONSTRAINT DF_dnp_Estatus_Brief_PAUSA DEFAULT (0),
        ESTATUS_AL_LIBERAR   VARCHAR(20)   NULL,     -- solo para ES_PAUSA = 1: a dónde regresa al aprobar/rechazar
        TITULO_AVISO         VARCHAR(100)  NULL,     -- aviso que muestra Brief al abrir un proyecto en este estatus
        MENSAJE_AVISO        VARCHAR(500)  NULL,
        CONSTRAINT PK_dnp_Estatus_Brief PRIMARY KEY (ID_STATUS),
        CONSTRAINT FK_dnp_Estatus_Brief_Liberar
            FOREIGN KEY (ESTATUS_AL_LIBERAR) REFERENCES dbo.dnp_Estatus_Brief (ID_STATUS),
        CONSTRAINT CK_dnp_Estatus_Brief_Liberar
            CHECK (ES_PAUSA = 1 OR ESTATUS_AL_LIBERAR IS NULL)
    );
END
GO

/* -------------------------------------------------------------------------------------
   2. dnp_Estatus_Brief_Transicion: cambios de estatus permitidos (ORIGEN -> DESTINO)
   ------------------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.dnp_Estatus_Brief_Transicion', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dnp_Estatus_Brief_Transicion
    (
        ORIGEN         VARCHAR(20) NOT NULL,
        DESTINO        VARCHAR(20) NOT NULL,
        REQUIERE_ADMIN BIT         NOT NULL CONSTRAINT DF_dnp_Estatus_Brief_Transicion_ADMIN DEFAULT (0),
        CONSTRAINT PK_dnp_Estatus_Brief_Transicion PRIMARY KEY (ORIGEN, DESTINO),
        CONSTRAINT FK_dnp_Estatus_Brief_Transicion_Origen
            FOREIGN KEY (ORIGEN)  REFERENCES dbo.dnp_Estatus_Brief (ID_STATUS),
        CONSTRAINT FK_dnp_Estatus_Brief_Transicion_Destino
            FOREIGN KEY (DESTINO) REFERENCES dbo.dnp_Estatus_Brief (ID_STATUS),
        CONSTRAINT CK_dnp_Estatus_Brief_Transicion_Distinto
            CHECK (ORIGEN <> DESTINO)
    );
END
GO

/* -------------------------------------------------------------------------------------
   3. dnp_Estatus_Brief_Historial: bitácora de cada cambio de estatus
   ------------------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.dnp_Estatus_Brief_Historial', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dnp_Estatus_Brief_Historial
    (
        ID_HISTORIAL    INT IDENTITY(1,1) NOT NULL,
        NO_PROYECTO     VARCHAR(50)  NOT NULL,
        ESTATUS_ORIGEN  VARCHAR(20)  NULL,
        ESTATUS_DESTINO VARCHAR(20)  NOT NULL,
        USUARIO         VARCHAR(50)  NOT NULL,
        MOTIVO          VARCHAR(200) NULL,
        ORIGEN_ACCION   VARCHAR(10)  NOT NULL,       -- 'MANUAL' | 'SISTEMA'
        FECHA           DATETIME     NOT NULL CONSTRAINT DF_dnp_Estatus_Brief_Historial_FECHA DEFAULT (GETDATE()),
        CONSTRAINT PK_dnp_Estatus_Brief_Historial PRIMARY KEY (ID_HISTORIAL),
        CONSTRAINT CK_dnp_Estatus_Brief_Historial_Accion CHECK (ORIGEN_ACCION IN ('MANUAL', 'SISTEMA'))
    );

    CREATE INDEX IX_dnp_Estatus_Brief_Historial_Proyecto
        ON dbo.dnp_Estatus_Brief_Historial (NO_PROYECTO, ID_HISTORIAL);
END
GO

/* -------------------------------------------------------------------------------------
   4. dnp_Brief_Admin: usuarios que pueden aprobar/rechazar y hacer cambios con REQUIERE_ADMIN
      USUARIO = SAMAccountName en MAYÚSCULAS, como lo guarda Session["User"] / Aprobaciones.
   ------------------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.dnp_Brief_Admin', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.dnp_Brief_Admin
    (
        USUARIO VARCHAR(50) NOT NULL,
        CONSTRAINT PK_dnp_Brief_Admin PRIMARY KEY (USUARIO)
    );
END
GO

/* -------------------------------------------------------------------------------------
   5. Columnas que usa Aprobaciones en dnp_Brief_Version (solo si faltan)
   ------------------------------------------------------------------------------------- */
IF COL_LENGTH('dbo.dnp_Brief_Version', 'USUARIO_APROBACION') IS NULL
    ALTER TABLE dbo.dnp_Brief_Version ADD USUARIO_APROBACION VARCHAR(50) NULL;
GO

IF COL_LENGTH('dbo.dnp_Brief_Version', 'MOTIVO') IS NULL
    ALTER TABLE dbo.dnp_Brief_Version ADD MOTIVO VARCHAR(MAX) NULL;
GO

/* Índice para las búsquedas de versión PENDIENTE por proyecto (candado y aprobación) */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_dnp_Brief_Version_Proyecto_Estatus'
                 AND object_id = OBJECT_ID('dbo.dnp_Brief_Version'))
    CREATE INDEX IX_dnp_Brief_Version_Proyecto_Estatus
        ON dbo.dnp_Brief_Version (NO_PROYECTO, ESTATUS);
GO

/* =====================================================================================
   EXPORTAR LA CONFIGURACIÓN (ejecutar en la base que YA funciona)
   Genera los INSERT de estatus, transiciones y administradores. Copia la columna
   "Script" del resultado y ejecútala en la base destino después de crear las tablas.
   Los INSERT son idempotentes (IF NOT EXISTS). Los estatus de pausa salen al final
   para que su ESTATUS_AL_LIBERAR ya exista (llave foránea).
   ===================================================================================== */
/*
SELECT Script FROM (
    SELECT 1 AS Grupo, ES_PAUSA AS Sub, ORDEN AS Orden,
        'IF NOT EXISTS (SELECT 1 FROM dbo.dnp_Estatus_Brief WHERE ID_STATUS = ''' + REPLACE(ID_STATUS, '''', '''''') + ''') ' +
        'INSERT INTO dbo.dnp_Estatus_Brief (ID_STATUS, ORDEN, ACTIVO, VISIBLE_EN_LISTA, SELECCIONABLE_MANUAL, PERMITE_EDICION, ' +
        'PERMITE_FIRMA, REINICIA_FIRMAS, ES_PAUSA, ESTATUS_AL_LIBERAR, TITULO_AVISO, MENSAJE_AVISO) VALUES (' +
        '''' + REPLACE(ID_STATUS, '''', '''''') + ''', ' +
        CAST(ISNULL(ORDEN, 0) AS VARCHAR(10)) + ', ' +
        CAST(ISNULL(ACTIVO, 1) AS VARCHAR(1)) + ', ' +
        CAST(ISNULL(VISIBLE_EN_LISTA, 1) AS VARCHAR(1)) + ', ' +
        CAST(ISNULL(SELECCIONABLE_MANUAL, 1) AS VARCHAR(1)) + ', ' +
        CAST(ISNULL(PERMITE_EDICION, 1) AS VARCHAR(1)) + ', ' +
        CAST(ISNULL(PERMITE_FIRMA, 0) AS VARCHAR(1)) + ', ' +
        CAST(ISNULL(REINICIA_FIRMAS, 0) AS VARCHAR(1)) + ', ' +
        CAST(ISNULL(ES_PAUSA, 0) AS VARCHAR(1)) + ', ' +
        ISNULL('''' + REPLACE(ESTATUS_AL_LIBERAR, '''', '''''') + '''', 'NULL') + ', ' +
        ISNULL('N''' + REPLACE(TITULO_AVISO, '''', '''''') + '''', 'NULL') + ', ' +
        ISNULL('N''' + REPLACE(MENSAJE_AVISO, '''', '''''') + '''', 'NULL') + ');' AS Script
    FROM dbo.dnp_Estatus_Brief

    UNION ALL
    SELECT 2, 0, 0,
        'IF NOT EXISTS (SELECT 1 FROM dbo.dnp_Estatus_Brief_Transicion WHERE ORIGEN = ''' + ORIGEN +
        ''' AND DESTINO = ''' + DESTINO + ''') INSERT INTO dbo.dnp_Estatus_Brief_Transicion (ORIGEN, DESTINO, REQUIERE_ADMIN) VALUES (''' +
        ORIGEN + ''', ''' + DESTINO + ''', ' + CAST(ISNULL(REQUIERE_ADMIN, 0) AS VARCHAR(1)) + ');'
    FROM dbo.dnp_Estatus_Brief_Transicion

    UNION ALL
    SELECT 3, 0, 0,
        'IF NOT EXISTS (SELECT 1 FROM dbo.dnp_Brief_Admin WHERE USUARIO = ''' + USUARIO +
        ''') INSERT INTO dbo.dnp_Brief_Admin (USUARIO) VALUES (''' + USUARIO + ''');'
    FROM dbo.dnp_Brief_Admin
) x
ORDER BY Grupo, Sub, Orden;
*/
GO
