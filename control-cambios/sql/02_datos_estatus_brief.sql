/* =====================================================================================
   Control de cambios del Brief - datos iniciales del catálogo de estatus
   Base: DNP

   Llena dnp_Estatus_Brief y dnp_Estatus_Brief_Transicion cuando están vacías:
     1. NUEVO
     2. Cualquier otro estatus que ya usen los proyectos (dnp_Cabecera_Brief.OTRO)
     3. PAUSA (control de cambios)
     4. Transiciones

   Las reglas por defecto reproducen el comportamiento de antes del control de cambios
   (todo editable y firmable, cambios manuales libres). Ajusta después los estatus que
   deban restringirse; ver la sección 5.

   Es idempotente: solo inserta lo que falta. Todo corre en una transacción.
   ===================================================================================== */
USE [DNP]
GO

SET XACT_ABORT ON;
BEGIN TRAN;

/* -------------------------------------------------------------------------------------
   1. NUEVO
   ------------------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM dbo.dnp_Estatus_Brief WHERE ID_STATUS = 'NUEVO')
    INSERT INTO dbo.dnp_Estatus_Brief
        (ID_STATUS, ORDEN, ACTIVO, VISIBLE_EN_LISTA, SELECCIONABLE_MANUAL,
         PERMITE_EDICION, PERMITE_FIRMA, REINICIA_FIRMAS, ES_PAUSA, ESTATUS_AL_LIBERAR,
         TITULO_AVISO, MENSAJE_AVISO)
    VALUES ('NUEVO', 1, 1, 1, 1, 1, 1, 0, 0, NULL, NULL, NULL);

/* -------------------------------------------------------------------------------------
   2. Estatus que ya usan los proyectos, con reglas de un estatus normal
   ------------------------------------------------------------------------------------- */
INSERT INTO dbo.dnp_Estatus_Brief
    (ID_STATUS, ORDEN, ACTIVO, VISIBLE_EN_LISTA, SELECCIONABLE_MANUAL,
     PERMITE_EDICION, PERMITE_FIRMA, REINICIA_FIRMAS, ES_PAUSA, ESTATUS_AL_LIBERAR,
     TITULO_AVISO, MENSAJE_AVISO)
SELECT x.OTRO,
       1 + ROW_NUMBER() OVER (ORDER BY x.OTRO),
       1, 1, 1,      -- ACTIVO, VISIBLE_EN_LISTA, SELECCIONABLE_MANUAL
       1, 1, 0, 0,   -- PERMITE_EDICION, PERMITE_FIRMA, REINICIA_FIRMAS, ES_PAUSA
       NULL, NULL, NULL
FROM (SELECT DISTINCT c.OTRO
      FROM dbo.dnp_Cabecera_Brief c
      WHERE c.OTRO IS NOT NULL AND LTRIM(RTRIM(c.OTRO)) <> ''
        AND c.OTRO NOT IN ('NUEVO', 'PAUSA')) x
WHERE NOT EXISTS (SELECT 1 FROM dbo.dnp_Estatus_Brief e WHERE e.ID_STATUS = x.OTRO);

/* -------------------------------------------------------------------------------------
   3. PAUSA: la asigna el sistema al hacer TERMINAR; bloquea edición y firma.
      Al aprobar o rechazar el cambio, el proyecto regresa a ESTATUS_AL_LIBERAR.
   ------------------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM dbo.dnp_Estatus_Brief WHERE ID_STATUS = 'PAUSA')
    INSERT INTO dbo.dnp_Estatus_Brief
        (ID_STATUS, ORDEN, ACTIVO, VISIBLE_EN_LISTA, SELECCIONABLE_MANUAL,
         PERMITE_EDICION, PERMITE_FIRMA, REINICIA_FIRMAS, ES_PAUSA, ESTATUS_AL_LIBERAR,
         TITULO_AVISO, MENSAJE_AVISO)
    VALUES ('PAUSA',
            (SELECT ISNULL(MAX(ORDEN), 0) + 1 FROM dbo.dnp_Estatus_Brief),
            1, 1, 0,      -- ACTIVO, VISIBLE_EN_LISTA, SELECCIONABLE_MANUAL (solo el sistema)
            0, 0, 0, 1,   -- PERMITE_EDICION, PERMITE_FIRMA, REINICIA_FIRMAS, ES_PAUSA
            'NUEVO',
            N'Proyecto en pausa',
            N'Este proyecto tiene un cambio pendiente de validación del Administrador. No es posible editarlo hasta que se apruebe o rechace.');

/* -------------------------------------------------------------------------------------
   4. Transiciones
   ------------------------------------------------------------------------------------- */
-- 4a. Cambios manuales entre estatus normales (combo de cambio de estatus): libres
INSERT INTO dbo.dnp_Estatus_Brief_Transicion (ORIGEN, DESTINO, REQUIERE_ADMIN)
SELECT o.ID_STATUS, d.ID_STATUS, 0
FROM dbo.dnp_Estatus_Brief o
CROSS JOIN dbo.dnp_Estatus_Brief d
WHERE o.ES_PAUSA = 0 AND d.ES_PAUSA = 0 AND o.ID_STATUS <> d.ID_STATUS
  AND NOT EXISTS (SELECT 1 FROM dbo.dnp_Estatus_Brief_Transicion t
                  WHERE t.ORIGEN = o.ID_STATUS AND t.DESTINO = d.ID_STATUS);

-- 4b. TERMINAR: de cualquier estatus editable a PAUSA
INSERT INTO dbo.dnp_Estatus_Brief_Transicion (ORIGEN, DESTINO, REQUIERE_ADMIN)
SELECT e.ID_STATUS, 'PAUSA', 0
FROM dbo.dnp_Estatus_Brief e
WHERE e.ES_PAUSA = 0 AND e.PERMITE_EDICION = 1
  AND NOT EXISTS (SELECT 1 FROM dbo.dnp_Estatus_Brief_Transicion t
                  WHERE t.ORIGEN = e.ID_STATUS AND t.DESTINO = 'PAUSA');

-- 4c. Aprobar o rechazar: salir de PAUSA (solo administradores de dnp_Brief_Admin)
IF NOT EXISTS (SELECT 1 FROM dbo.dnp_Estatus_Brief_Transicion WHERE ORIGEN = 'PAUSA' AND DESTINO = 'NUEVO')
    INSERT INTO dbo.dnp_Estatus_Brief_Transicion (ORIGEN, DESTINO, REQUIERE_ADMIN)
    VALUES ('PAUSA', 'NUEVO', 1);

COMMIT;
GO

/* -------------------------------------------------------------------------------------
   5. Revisión
   ------------------------------------------------------------------------------------- */
-- Catálogo resultante. Ajusta con UPDATE los estatus que deban restringirse, por ejemplo:
--   UPDATE dnp_Estatus_Brief SET PERMITE_EDICION = 0 WHERE ID_STATUS = 'CERRADO';    -- solo lectura
--   UPDATE dnp_Estatus_Brief SET VISIBLE_EN_LISTA = 0 WHERE ID_STATUS = 'CANCELADO'; -- ocultar de la lista
--   UPDATE dnp_Estatus_Brief SET PERMITE_FIRMA = 0 WHERE ID_STATUS = 'NUEVO';        -- no firmar aún
SELECT ID_STATUS, ORDEN, ACTIVO, VISIBLE_EN_LISTA, SELECCIONABLE_MANUAL,
       PERMITE_EDICION, PERMITE_FIRMA, REINICIA_FIRMAS, ES_PAUSA, ESTATUS_AL_LIBERAR
FROM dbo.dnp_Estatus_Brief
ORDER BY ORDEN;

-- Debe regresar 0: proyectos que siguen sin aparecer en la lista de Brief
SELECT COUNT(*) AS ProyectosOcultos
FROM dbo.view_dnp_proyectosBrief v
LEFT JOIN dbo.dnp_Estatus_Brief e ON e.ID_STATUS = v.OTRO
WHERE e.ID_STATUS IS NULL;
GO
