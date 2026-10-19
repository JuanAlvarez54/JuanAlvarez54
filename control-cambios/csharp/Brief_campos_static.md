# Brief.aspx.cs: quitar los campos `static`

## Por qué

```csharp
internal static string formabotella, colorbotella, tipoMaquila, tipotapa, colortapa, terminadotapa, linnertapa,
    MatEtiqueta, TerminadoEtiqueta, MatFunda, TermiFunda, impresionFunda, MatTubo, TermiTubo, MatBobina, TermiBobina,
    MatCorrugado, terminadoCorr, pzasCorru, formula, terminadosf, colorf, bloqueadores;
```

Un campo `static` en una página ASP.NET es **uno solo para todo el servidor**: lo comparten todos los usuarios y todos los proyectos. Cuando en una sección no hay ninguna opción marcada, el `Actualiza*` no asigna el valor y se queda con **el último que eligió cualquier usuario en cualquier proyecto**. Ese valor se guarda en la BD y además la validación `== null` no lo detecta.

Casos reales en el código actual:

| Método | Campo | Qué pasa hoy si no hay nada marcado |
|---|---|---|
| `ActualizaCabecera` | `tipoMaquila` | Guarda el tipo de maquila de otro proyecto; la validación `tipoMaquila == null` nunca se cumple. |
| `ActualizaFunda` | `impresionFunda` | Guarda la impresión de otro proyecto. Los demás campos sí se ponen en `null`. |
| `ActualizaFormula` | `formula`, `colorf`, `terminadosf`, `bloqueadores` | Guarda valores de otro proyecto. El comentario "si no, bloqueadores queda null" es falso. |

## Ningún valor necesita sobrevivir entre postbacks

Revisé cada lectura de esos campos:

- Todos los `Actualiza*` calculan el valor **en ese momento**, leyendo `.Checked` de los RadioButton. ASP.NET conserva el estado marcado entre postbacks, así que no hace falta guardarlo aparte.
- `GetCheckedRB` asigna los campos, pero ningún `Actualiza*` usa esas asignaciones: siempre los vuelven a calcular. Las únicas partes de `GetCheckedRB` que sirven son las que ajustan la pantalla (desmarcar otras opciones, habilitar `txtOtroColorf`).
- `formabotella`, `colorbotella`, `tipotapa`, `colortapa`, `terminadotapa`, `linnertapa`, `MatCorrugado`, `terminadoCorr` y `pzasCorru` **nunca se leen**. `ActualizaBotella`, `ActualizaTapa` y `ActualizaCorrugado` usan sus propias variables o los controles.

Por eso los campos se pueden convertir en **variables locales**. El único cambio de comportamiento es el que se busca: si no hay opción marcada, el valor es `null` y no el de otro proyecto.

`req_legal` no es `static`, pero tiene el problema inverso: es un campo de instancia, así que vale `'\0'` en cada postback salvo cuando el RadioButton cambió en ese mismo postback. Además, la validación `req_legal.ToString() == ""` nunca se cumple. Se corrige aquí también.

---

## Cambios

### 1. Borrar las declaraciones

Borra estas dos líneas del inicio de la clase:

```csharp
internal static string formabotella, colorbotella, tipoMaquila, tipotapa, colortapa, terminadotapa, linnertapa, MatEtiqueta, TerminadoEtiqueta, MatFunda, TermiFunda, impresionFunda, MatTubo, TermiTubo, MatBobina, TermiBobina, MatCorrugado, terminadoCorr, pzasCorru,formula, terminadosf, colorf, bloqueadores;
char req_legal;
```

> Son `internal`. Antes de borrarlas, busca en toda la solución `Brief.tipoMaquila`, `Brief.formula`, etc. Si otra página las usa, el compilador te lo marcará.

### 2. `ActualizaCabecera`: una línea al inicio del `try`

```csharp
try
{
    string tipoMaquila = null;   // <- agregar

    if (FULLSERVICE.Checked)
    ...
```

El resto del método no cambia: ahora `tipoMaquila` es la variable local y `tipoMaquila == null` sí detecta que falta elegir el tipo de maquila.

### 3. `ActualizaFunda`: una línea al inicio del `try`

```csharp
try
{
    string MatEtiqueta = null, TerminadoEtiqueta = null, MatFunda = null, TermiFunda = null, impresionFunda = null,
           MatTubo = null, TermiTubo = null, MatBobina = null, TermiBobina = null;   // <- agregar

    if (BOPPBCO.Checked)
    ...
```

### 4. `ActualizaFormula`: una línea al inicio del `try`

```csharp
try
{
    string formula = null, colorf = null, terminadosf = null, bloqueadores = null;   // <- agregar

    //TIPO DE FORMULA
    if (CONTRATIPOF.Checked)
    ...
```

> Si un usuario guarda Fórmula sin marcar el tipo (Contratipo / Línea / Otros), ahora se envía `null` a `sp_ActualizaFromulaBrief`, igual que pasaba justo después de reiniciar el servidor. Si esa columna no acepta `NULL`, agrega `formula == null` a la validación de "Favor de llenar todos los datos".

### 5. `ActualizaTapa`: borrar dos líneas

Dentro de `//LINNER DE TAPA`, borra las dos asignaciones que no se usan:

```csharp
linnertapa = CONLINNER.ID;   // <- borrar
...
linnertapa = SINLINNER.ID;   // <- borrar
```

### 6. `GetCheckedRB`: reemplazar el método completo

Las ramas que solo asignaban un campo se eliminan. Las que ajustan la pantalla quedan **con las mismas instrucciones** de antes, agrupadas porque eran idénticas por pares.

```csharp
// Solo ajusta la pantalla al marcar una opción; los valores se leen de los controles al guardar (Actualiza*).
protected void GetCheckedRB(object sender, EventArgs e)
{
    try
    {
        RadioButton cbSeleccionado = (RadioButton)sender;
        if (!cbSeleccionado.Checked)
            return;

        switch (cbSeleccionado.GroupName)
        {
            case "MatEtiq":
            case "TerminadoEti":
                materialtipoEti.Checked = true;
                materialtipofunda.Checked = false;
                PETG.Checked = false;
                OtroFunda.Checked = false;
                txtOtrosFunda.Text = "";
                MATEF.Checked = false;
                BRILLANTEF.Checked = false;
                BILAMINADO.Checked = false;
                TRILAMINADO.Checked = false;
                SURLYN.Checked = false;
                OTROSBOBINA.Checked = false;
                txtOtrosBobina.Text = "";
                break;

            case "MaterialFunda":
            case "TerminadoFunda":
                materialtipoEti.Checked = false;
                materialtipofunda.Checked = true;
                BOPPBCO.Checked = false;
                BOPPTRANSP.Checked = false;
                BOPPMET.Checked = false;
                MATEETI.Checked = false;
                BRILLANTEETI.Checked = false;
                BILAMINADO.Checked = false;
                TRILAMINADO.Checked = false;
                SURLYN.Checked = false;
                OTROSBOBINA.Checked = false;
                txtOtrosBobina.Text = "";
                break;

            case "MaterialBobina":
            case "Terminadobobina":
                materialtiposachet.Checked = true;
                BOPPBCO.Checked = false;
                BOPPTRANSP.Checked = false;
                BOPPMET.Checked = false;
                MATEETI.Checked = false;
                BRILLANTEETI.Checked = false;
                PETG.Checked = false;
                OtroFunda.Checked = false;
                txtOtrosFunda.Text = "";
                MATEF.Checked = false;
                BRILLANTEF.Checked = false;
                MONOCAPA.Checked = false;
                BICAPA.Checked = false;
                COEXTRUIDO.Checked = false;
                MATETU.Checked = false;
                BRILLANTETU.Checked = false;
                break;

            case "colorf":
                txtOtroColorf.Enabled = cbSeleccionado.ID == "chColorF";
                txtOtroColorf.Text = "";
                break;
        }
    }
    catch
    {
        MostrarToast("Error al seleccionar botones.", ToastTipo.Error);
    }
}
```

### 7. Legales: leer el requisito de los RadioButton

Reemplaza `ActualizaLegales` completo:

```csharp
protected void ActualizaLegales(object sender, EventArgs e)
{
    if (EdicionBloqueada()) return;
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
            db.sp_ActualizaLegalBrief(lblProyectoCotiza.Text, txtlegal.Text, txtotrosobs.Text, reqLegal, txtEsp.Text);
        }

        MostrarToast("Guardado Correctamente.", ToastTipo.Success);
    }
    catch
    {
        MostrarToast("Error al actualizar legales.", ToastTipo.Error);
    }
}
```

En los dos eventos de los RadioButton, quita la asignación a `req_legal`:

```csharp
protected void radbtn_si_CheckedChanged(object sender, EventArgs e)
{
    txtEsp.Enabled = true;
}

protected void radbtn_no_CheckedChanged(object sender, EventArgs e)
{
}
```

Con el código anterior pudieron quedar registros con un requisito legal inválido (`'\0'`). Revísalos:

```sql
SELECT NO_PROYECTO, REQUIS_LEGAL, UNICODE(REQUIS_LEGAL) AS Codigo
FROM dnp_LegalesBrief
WHERE REQUIS_LEGAL IS NULL OR REQUIS_LEGAL NOT IN ('Y', 'N');
```

Esos proyectos aparecen sin "Sí" ni "No" marcado en Legales; basta con abrirlos, elegir la opción y guardar.

---

## Prueba

1. **Compilar.** Si alguna otra página usaba `Brief.<campo>`, aquí aparece.
2. **Dos navegadores, dos usuarios, dos proyectos:**
   - En A, guarda Fórmula con `MODELADORA`.
   - En B, guarda Fórmula **sin** marcar fijación. Debe salir "Favor de llenar todos los datos". Antes se guardaba `MODELADORA`.
3. **Cabecera sin tipo de maquila:** debe pedir los datos.
4. **Legales:** guarda con "Sí" y con "No", recarga el proyecto y verifica que queda marcada la opción correcta.
