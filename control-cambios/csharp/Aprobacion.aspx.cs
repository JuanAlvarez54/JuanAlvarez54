using System;
using System.Collections.Generic;
using System.Configuration;
using System.Data;
using System.Data.SqlClient;
using System.Drawing;
using System.Linq;
using System.Web;
using System.Web.UI;
using System.Web.UI.WebControls;
using System.Net.Mail;
using System.IO;
using DNP;
using System.Security.Policy;

namespace TG_DNP
{
    public partial class Aprobacion : System.Web.UI.Page
    {
        cIdentificacion clIdent = new cIdentificacion();

        protected void Page_Load(object sender, EventArgs e)
        {
            if (!IsPostBack)
            {
                MultiView1.ActiveViewIndex = 0;
                cargaProyectos();
            }
        }

        // Cada aviso con clave única: con la misma clave ASP.NET ignora los registros repetidos
        // y un aviso tapaba al otro. El texto se escapa para no romper el script.
        private void Toast(string tipo, string mensaje)
        {
            string script = "toastr." + tipo + "(" + HttpUtility.JavaScriptStringEncode(mensaje, true) + ");";
            ScriptManager.RegisterStartupScript(this, GetType(), "toast_" + Guid.NewGuid().ToString("N"), script, true);
        }

        public void cargaProyectos()
        {
            string buscar = "PROYECTO";

            try
            {
                clUtil oUtil = new clUtil();
                SqlCommand cmdWH = new SqlCommand();
                using (cmdWH)
                {
                    cmdWH.Connection = oUtil.ADOS_DH;
                    cmdWH.CommandType = CommandType.StoredProcedure;
                    cmdWH.CommandText = "dnp_spObtenerAprobacion";

                    cmdWH.Parameters.Add("@busqueda", SqlDbType.VarChar);
                    cmdWH.Parameters["@busqueda"].Value = buscar;

                    SqlDataAdapter dataAdapter = new SqlDataAdapter(cmdWH);
                    DataSet dataSet = new DataSet();
                    dataAdapter.Fill(dataSet);

                    dgAprobacion.DataSource = dataSet.Tables[0].DefaultView;
                    dgAprobacion.DataBind();
                    cmdWH.Connection.Close();
                    oUtil = null;

                    dgAprobacion.SelectedIndex = -1;
                }
            }
            catch
            {
                Toast("error", "Error al cargar proyectos.");
            }
        }

        // ===== Aprobación / rechazo de versiones =====

        protected void btnAprobar_Click(object sender, EventArgs e)
        {
            Resolver("APROBADO", "aprobar", "aprobada");
        }

        protected void btnRechazar_Click(object sender, EventArgs e)
        {
            Resolver("RECHAZADO", "rechazar", "rechazada");
        }

        private void Resolver(string estatusFinal, string verbo, string participio)
        {
            string usuario = Convert.ToString(Session["User"]).Trim().ToUpper();
            string proyecto = lblProyectoCotiza.Text;
            string version = Convert.ToString(ViewState["VersionSeleccionada"]);

            if (usuario == "")
            {
                Toast("warning", "Tu sesión expiró. Vuelve a iniciar sesión para continuar.");
                return;
            }

            if (!EsAdministrador(usuario))
            {
                Toast("info", "Acceso denegado. No tiene permiso para " + verbo + " esta versión.");
                return;
            }

            if (string.IsNullOrEmpty(proyecto) || version == "")
            {
                Toast("warning", "Debe seleccionar una versión de la lista para " + verbo + ".");
                return;
            }

            if (string.IsNullOrWhiteSpace(txtbx_comments.Text))
            {
                Toast("warning", "Debe ingresar un comentario para " + verbo + " la versión.");
                return;
            }

            if (ResolverVersion(usuario, proyecto, version, estatusFinal))
            {
                dgAprobacion.SelectedIndex = -1;
                txtbx_comments.Text = string.Empty;
                ViewState["VersionSeleccionada"] = null;
                clIdent.CargarDataGrid(ref dgAprobacion, "PROYECTO", "dnp_spObtenerAprobacion");

                Toast("success", "La versión ha sido " + participio + " correctamente.");
            }
        }

        // Misma fuente de verdad que los SP (dnp_spBriefCambiarEstatus): la tabla dnp_Brief_Admin.
        private bool EsAdministrador(string usuario)
        {
            clUtil oUtil = new clUtil();
            using (SqlConnection cnx = oUtil.ADOS_DH)
            using (SqlCommand cmd = new SqlCommand("SELECT COUNT(*) FROM dnp_Brief_Admin WHERE USUARIO = @u", cnx))
            {
                if (cnx.State != ConnectionState.Open) cnx.Open();
                cmd.Parameters.Add("@u", SqlDbType.VarChar, 50).Value = usuario;
                return Convert.ToInt32(cmd.ExecuteScalar()) > 0;
            }
        }

        // Marca la versión como APROBADO/RECHAZADO y libera la pausa en una sola transacción.
        // Devuelve true solo si todo se confirmó; cualquier error se muestra con su mensaje real.
        private bool ResolverVersion(string usuario, string proyecto, string version, string estatusFinal)
        {
            clUtil oUtil = new clUtil();
            using (SqlConnection cnx = oUtil.ADOS_DH)
            {
                if (cnx.State != ConnectionState.Open) cnx.Open();

                using (SqlTransaction trx = cnx.BeginTransaction())
                {
                    try
                    {
                        BloquearProyectoBrief(cnx, trx, proyecto);

                        const string sSql = @"UPDATE dnp_Brief_Version
                                              SET ESTATUS = @estatus,
                                                  FECHAAPROB = @fecha,
                                                  USUARIO_APROBACION = @usuario,
                                                  MOTIVO = @motivo
                                              WHERE NO_PROYECTO = @proyecto
                                                AND VERSION = @version
                                                AND ESTATUS = 'PENDIENTE'";

                        using (SqlCommand cmd = new SqlCommand(sSql, cnx, trx))
                        {
                            cmd.Parameters.Add("@estatus", SqlDbType.VarChar).Value = estatusFinal;
                            cmd.Parameters.Add("@fecha", SqlDbType.Date).Value = DateTime.Today;
                            cmd.Parameters.Add("@usuario", SqlDbType.VarChar).Value = usuario;
                            cmd.Parameters.Add("@motivo", SqlDbType.VarChar).Value = txtbx_comments.Text;
                            cmd.Parameters.Add("@proyecto", SqlDbType.VarChar).Value = proyecto;
                            cmd.Parameters.Add("@version", SqlDbType.VarChar).Value = version;

                            if (cmd.ExecuteNonQuery() == 0)
                            {
                                trx.Rollback();
                                Toast("info", "No se encontró la versión " + version + " del proyecto " + proyecto +
                                              " en estatus PENDIENTE.");
                                return false;
                            }
                        }

                        LiberarPausaBrief(cnx, trx, proyecto, usuario);
                        trx.Commit();
                        return true;
                    }
                    catch (Exception ex)
                    {
                        // Con XACT_ABORT el servidor ya pudo revertir; que el Rollback no tape el error real
                        try { if (trx.Connection != null) trx.Rollback(); } catch { }

                        System.Diagnostics.Trace.TraceError(ex.ToString());

                        // Errores >= 50000 son mensajes de negocio de los SP. El resto se muestra con detalle
                        // para diagnosticar (p. ej. un SP faltante); cámbialo por un texto fijo cuando ya esté estable.
                        SqlException sqlEx = ex as SqlException;
                        Toast("error", sqlEx != null && sqlEx.Number >= 50000
                            ? sqlEx.Message
                            : "Error al procesar la versión: " + ex.Message);
                        return false;
                    }
                }
            }
        }

        // Toma el bloqueo del proyecto ANTES de actualizar la versión, con el mismo orden que usan
        // los SP del Brief; evita interbloqueos con TERMINAR o cambios de estatus.
        private void BloquearProyectoBrief(SqlConnection cnx, SqlTransaction trx, string proyecto)
        {
            using (SqlCommand cmd = new SqlCommand("dnp_spBriefBloquear", cnx, trx))
            {
                cmd.CommandType = CommandType.StoredProcedure;
                cmd.Parameters.Add("@Proyecto", SqlDbType.VarChar, 20).Value = proyecto;
                cmd.ExecuteNonQuery();
            }
        }

        // Libera el proyecto de PAUSA (si aplica) en la misma transacción que la aprobación o rechazo.
        private void LiberarPausaBrief(SqlConnection cnx, SqlTransaction trx, string proyecto, string usuario)
        {
            string motivo = txtbx_comments.Text ?? "";
            if (motivo.Length > 200) motivo = motivo.Substring(0, 200);

            using (SqlCommand cmd = new SqlCommand("dnp_spBriefLiberarPausa", cnx, trx))
            {
                cmd.CommandType = CommandType.StoredProcedure;
                cmd.Parameters.Add("@Proyecto", SqlDbType.VarChar, 20).Value = proyecto;
                cmd.Parameters.Add("@Usuario", SqlDbType.VarChar, 50).Value = usuario;
                cmd.Parameters.Add("@Motivo", SqlDbType.VarChar, 200).Value = motivo;
                cmd.ExecuteNonQuery();
            }
        }

        public bool actualizaFechaVersion(string codigoPerfil)
        {
            bool Str = true;

            clUtil oUtil = new clUtil();

            oUtil.cmdWH.CommandType = CommandType.StoredProcedure;
            oUtil.cmdWH.CommandText = "dnp_spFechaVersion";

            oUtil.cmdWH.Parameters.Add("@Codigo", SqlDbType.Text);
            oUtil.cmdWH.Parameters["@Codigo"].Value = codigoPerfil;

            bool proc = Convert.ToBoolean(oUtil.cmdWH.ExecuteNonQuery());

            if (proc)
            {
                Str = true;
            }
            else
            {
                Str = false;
            }
            oUtil = null;
            return Str;
        }

        // ===== Grilla =====

        // Texto de una celda del DataGrid sin codificación HTML (&nbsp;, &amp;...) ni espacios.
        private static string ValorCelda(TableCell celda)
        {
            return HttpUtility.HtmlDecode(celda.Text ?? "").Replace(' ', ' ').Trim();
        }

        protected void DataGrid1_SortCommand(object source, DataGridSortCommandEventArgs e)
        {
            clIdent.CargarDataGrid(ref dgAprobacion, e.SortExpression, "dnp_spObtenerAprobacion");
        }

        protected void DataGrid1_ItemCommand(object source, DataGridCommandEventArgs e)
        {
            if (e.CommandName == "Seleccionar" || e.CommandName == "Select")
            {
                // Columnas de dnp_spObtenerAprobacion tras la columna del botón:
                // [1] PROYECTO, [2] PRODUCTO, [3] VERSION, [4] ESTATUS, [5] USUARIO
                lblProyectoCotiza.Text = ValorCelda(e.Item.Cells[1]);
                ViewState["VersionSeleccionada"] = ValorCelda(e.Item.Cells[3]);
            }
        }

        protected void DataGrid1_SelectedIndexChanged(object sender, EventArgs e)
        {

        }

        // ===== Filtros =====

        public void FiltraProyectos()
        {
            try
            {
                string filtro = DropFiltro.SelectedValue;

                if (!string.IsNullOrEmpty(filtro) && filtro != "SELECCIONE")
                {
                    clUtil oUtil = new clUtil();

                    using (SqlCommand cmdWH = new SqlCommand("sp_FiltraAprobaciones", oUtil.ADOS_DH))
                    {
                        cmdWH.CommandType = CommandType.StoredProcedure;
                        cmdWH.Parameters.Add("@filtro", SqlDbType.VarChar).Value = filtro;

                        SqlDataAdapter dataAdapter = new SqlDataAdapter(cmdWH);
                        DataSet dataSet = new DataSet();

                        if (oUtil.ADOS_DH.State == ConnectionState.Closed)
                            oUtil.ADOS_DH.Open();

                        dataAdapter.Fill(dataSet);

                        if (dataSet.Tables.Count > 0 && dataSet.Tables[0].Rows.Count > 0)
                        {
                            dgAprobacion.DataSource = dataSet.Tables[0];
                            dgAprobacion.DataBind();
                        }
                        else
                        {
                            dgAprobacion.DataSource = null;
                            dgAprobacion.DataBind();

                            Toast("error", "No se encontraron registros para el estatus " + filtro);
                        }
                    }
                    oUtil.ADOS_DH.Close();
                }
                else
                {
                    dgAprobacion.DataSource = null;
                    dgAprobacion.DataBind();
                }
            }
            catch
            {
                Toast("error", "Error al filtrar proyectos.");
            }
        }

        protected void btnFiltrar_Click(object sender, EventArgs e)
        {
            FiltraProyectos();
        }

        protected void DropFiltro_SelectedIndexChanged(object sender, EventArgs e)
        {

        }

        protected void txtBusqueda_TextChanged(object sender, EventArgs e)
        {

        }

        protected void btnBusca_Click(object sender, EventArgs e)
        {
            FiltraProyectosB(txtBusqueda.Text);
        }

        protected void chArchivado_CheckedChanged(object sender, EventArgs e)
        {

        }

        public void FiltraProyectosB(string proyecto)
        {
            try
            {
                string parametro = proyecto != "" ? proyecto : "PROYECTO";
                clIdent.CargarDataGrid(ref dgAprobacion, parametro, "dnp_spObtenerAprobacion");
                dgAprobacion.SelectedIndex = -1;
            }
            catch
            {
                Toast("error", "Error al filtrar proyectos.");
            }
        }
    }
}
