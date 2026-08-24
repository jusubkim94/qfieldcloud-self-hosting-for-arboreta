using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

[assembly: AssemblyTitle("QFieldCloud Standalone Template Editor")]
[assembly: AssemblyDescription("Offline GUI editor for the unofficial QFieldCloud lab-lightsail CloudFormation template")]
[assembly: AssemblyCompany("qfieldcloud-self-hosting-for-arboreta contributors")]
[assembly: AssemblyProduct("QFieldCloud Standalone Template Editor")]
[assembly: AssemblyVersion("0.1.1.0")]
[assembly: AssemblyFileVersion("0.1.1.0")]

namespace QFieldCloudTemplateEditor
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "--self-test")
            {
                return RunSelfTest();
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            if (args.Length > 1 && args[0] == "--render-test")
            {
                try
                {
                    using (MainForm renderForm = new MainForm()) renderForm.RenderTestScreenshots(args[1]);
                    return 0;
                }
                catch
                {
                    return 98;
                }
            }
            Application.Run(new MainForm());
            return 0;
        }

        private static int RunSelfTest()
        {
            try
            {
                string yaml = TemplateEngine.LoadEmbeddedTemplate();
                List<ValidationIssue> before = TemplateEngine.Validate(yaml);
                if (TemplateEngine.HasErrors(before)) return 11;

                string edited = TemplateEngine.ApplyGuidedSettings(
                    yaml,
                    "ap-northeast-2",
                    "ap-northeast-2b",
                    "qfieldcloud-self-test",
                    "ubuntu_24_04",
                    "large_3_0",
                    "self-signed",
                    false,
                    150,
                    1);
                if (!edited.Contains("BundleId: large_3_0")) return 12;
                if (!edited.Contains("Default: qfieldcloud-self-test")) return 13;
                if (!edited.Contains("Default: ap-northeast-2b")) return 14;
                if (TemplateEngine.HasErrors(TemplateEngine.Validate(edited))) return 15;
                return 0;
            }
            catch
            {
                return 99;
            }
        }
    }

    internal sealed class BundleOption
    {
        public readonly string Id;
        public readonly string Label;
        public readonly decimal MonthlyUsd;
        public readonly decimal MemoryGb;

        public BundleOption(string id, string label, decimal monthlyUsd, decimal memoryGb)
        {
            Id = id;
            Label = label;
            MonthlyUsd = monthlyUsd;
            MemoryGb = memoryGb;
        }

        public override string ToString()
        {
            return Label;
        }
    }

    internal sealed class ValidationIssue
    {
        public readonly string Severity;
        public readonly string Location;
        public readonly string Message;

        public ValidationIssue(string severity, string location, string message)
        {
            Severity = severity;
            Location = location;
            Message = message;
        }
    }

    internal static class TemplateEngine
    {
        private const string ResourceName = "QFieldCloudTemplateEditor.DefaultTemplate.yaml";

        public static string LoadEmbeddedTemplate()
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream stream = assembly.GetManifestResourceStream(ResourceName))
            {
                if (stream == null) throw new InvalidOperationException("내장 template.yaml을 찾을 수 없습니다.");
                using (StreamReader reader = new StreamReader(stream, new UTF8Encoding(false), true))
                {
                    return reader.ReadToEnd();
                }
            }
        }

        public static string GetParameterDefault(string yaml, string parameterName)
        {
            string pattern = "(?ms)(^  " + Regex.Escape(parameterName) + ":\\r?\\n(?:(?!^  \\S).)*?^    Default:\\s*)(?<value>[^\\r\\n]+)";
            Match match = Regex.Match(yaml, pattern);
            return match.Success ? Unquote(match.Groups["value"].Value.Trim()) : String.Empty;
        }

        public static string GetResourceProperty(string yaml, string resourceName, string propertyName)
        {
            string pattern = "(?ms)(^  " + Regex.Escape(resourceName) + ":\\r?\\n(?:(?!^  \\S).)*?^      " + Regex.Escape(propertyName) + ":\\s*)(?<value>[^\\r\\n]+)";
            Match match = Regex.Match(yaml, pattern);
            return match.Success ? Unquote(match.Groups["value"].Value.Trim()) : String.Empty;
        }

        public static string ApplyGuidedSettings(
            string yaml,
            string region,
            string availabilityZone,
            string instanceName,
            string blueprintId,
            string bundleId,
            string certificateMode,
            bool letsEncryptAccepted,
            int waitMinutes,
            int alarmThreshold)
        {
            string result = yaml;
            string previousRegion = GetParameterDefault(result, "DeploymentRegion");
            if (!String.IsNullOrWhiteSpace(previousRegion) && previousRegion != region)
            {
                result = result.Replace(previousRegion, region);
            }

            result = ReplaceParameterDefault(result, "DeploymentRegion", region, false);
            result = ReplaceParameterDefault(result, "AvailabilityZone", availabilityZone, false);
            result = ReplaceParameterDefault(result, "InstanceName", instanceName, false);
            result = ReplaceParameterDefault(result, "CertificateMode", certificateMode, false);
            result = ReplaceParameterDefault(result, "LetsEncryptTermsAccepted", letsEncryptAccepted ? "true" : "false", true);
            result = ReplaceResourceProperty(result, "LightsailInstance", "BlueprintId", blueprintId, false);
            result = ReplaceResourceProperty(result, "LightsailInstance", "BundleId", bundleId, false);
            result = ReplaceResourceProperty(result, "BootstrapWaitCondition", "Timeout", (waitMinutes * 60).ToString(), true);
            result = ReplaceResourceProperty(result, "StatusCheckFailedAlarm", "Threshold", alarmThreshold.ToString(), false);
            return result;
        }

        private static string ReplaceParameterDefault(string yaml, string parameterName, string value, bool quote)
        {
            string pattern = "(?ms)(^  " + Regex.Escape(parameterName) + ":\\r?\\n(?:(?!^  \\S).)*?^    Default:\\s*)[^\\r\\n]+";
            Match match = Regex.Match(yaml, pattern);
            if (!match.Success) throw new InvalidOperationException("Parameters." + parameterName + ".Default를 찾을 수 없습니다.");
            return new Regex(pattern).Replace(yaml, delegate(Match m) { return m.Groups[1].Value + (quote ? Quote(value) : value); }, 1);
        }

        private static string ReplaceResourceProperty(string yaml, string resourceName, string propertyName, string value, bool quote)
        {
            string pattern = "(?ms)(^  " + Regex.Escape(resourceName) + ":\\r?\\n(?:(?!^  \\S).)*?^      " + Regex.Escape(propertyName) + ":\\s*)[^\\r\\n]+";
            Match match = Regex.Match(yaml, pattern);
            if (!match.Success) throw new InvalidOperationException("Resources." + resourceName + "." + propertyName + "을 찾을 수 없습니다.");
            return new Regex(pattern).Replace(yaml, delegate(Match m) { return m.Groups[1].Value + (quote ? Quote(value) : value); }, 1);
        }

        private static string Quote(string value)
        {
            return "'" + value.Replace("'", "''") + "'";
        }

        private static string Unquote(string value)
        {
            if (value.Length >= 2 && ((value[0] == '\'' && value[value.Length - 1] == '\'') || (value[0] == '"' && value[value.Length - 1] == '"')))
            {
                return value.Substring(1, value.Length - 2);
            }
            return value;
        }

        public static List<ValidationIssue> Validate(string yaml)
        {
            List<ValidationIssue> issues = new List<ValidationIssue>();
            if (String.IsNullOrWhiteSpace(yaml))
            {
                issues.Add(new ValidationIssue("오류", "문서", "YAML 내용이 비어 있습니다."));
                return issues;
            }

            Required(yaml, "AWSTemplateFormatVersion:", "문서", "CloudFormation 형식 버전", issues);
            Required(yaml, "Parameters:", "문서", "Parameters 구역", issues);
            Required(yaml, "Resources:", "문서", "Resources 구역", issues);
            Required(yaml, "Outputs:", "문서", "Outputs 구역", issues);
            Required(yaml, "Type: AWS::Lightsail::Instance", "Resources", "Lightsail 인스턴스", issues);
            Required(yaml, "Type: AWS::Lightsail::StaticIp", "Resources", "고정 IP", issues);
            Required(yaml, "Type: AWS::CloudFormation::WaitCondition", "Resources", "설치 완료 대기 조건", issues);

            int nodeCount = Regex.Matches(yaml, "(?m)^    Type: AWS::Lightsail::Instance\\s*$").Count;
            if (nodeCount != 1)
            {
                issues.Add(new ValidationIssue("오류", "Resources", "standalone 템플릿은 Lightsail 인스턴스가 정확히 1개여야 합니다. 현재 " + nodeCount + "개입니다."));
            }

            string region = GetParameterDefault(yaml, "DeploymentRegion");
            string zone = GetParameterDefault(yaml, "AvailabilityZone");
            string name = GetParameterDefault(yaml, "InstanceName");
            string blueprint = GetResourceProperty(yaml, "LightsailInstance", "BlueprintId");
            string bundle = GetResourceProperty(yaml, "LightsailInstance", "BundleId");
            string cert = GetParameterDefault(yaml, "CertificateMode");

            if (!Regex.IsMatch(region, "^[a-z]{2}(?:-[a-z]+)+-[0-9]+$"))
                issues.Add(new ValidationIssue("오류", "Parameters.DeploymentRegion", "AWS Region 형식이 올바르지 않습니다."));
            if (!zone.StartsWith(region, StringComparison.Ordinal) || !Regex.IsMatch(zone, "[a-z]$"))
                issues.Add(new ValidationIssue("오류", "Parameters.AvailabilityZone", "Availability Zone은 선택한 Region으로 시작하고 영문 소문자로 끝나야 합니다."));
            if (!Regex.IsMatch(name, "^[A-Za-z0-9][A-Za-z0-9_.-]{1,62}[A-Za-z0-9]$"))
                issues.Add(new ValidationIssue("오류", "Parameters.InstanceName", "인스턴스 이름은 3~64자의 영문, 숫자, 점, 밑줄, 하이픈이어야 합니다."));
            if (String.IsNullOrWhiteSpace(bundle))
                issues.Add(new ValidationIssue("오류", "LightsailInstance.BundleId", "Lightsail Bundle ID가 비어 있습니다."));
            if (String.IsNullOrWhiteSpace(blueprint))
                issues.Add(new ValidationIssue("오류", "LightsailInstance.BlueprintId", "Lightsail Blueprint ID가 비어 있습니다."));
            else if (blueprint != "ubuntu_24_04")
                issues.Add(new ValidationIssue("경고", "LightsailInstance.BlueprintId", "설치 스크립트는 ubuntu_24_04에서만 검증되었습니다. 다른 OS는 apt 명령 때문에 실패할 수 있습니다."));
            if (bundle == "nano_3_0" || bundle == "micro_3_0" || bundle == "small_3_0")
                issues.Add(new ValidationIssue("경고", "LightsailInstance.BundleId", "4GB 미만 사양은 QFieldCloud 전체 구성에 부족할 가능성이 높으며 검증되지 않았습니다."));
            if (cert != "self-signed" && cert != "letsencrypt-ip")
                issues.Add(new ValidationIssue("오류", "Parameters.CertificateMode", "인증서 모드는 self-signed 또는 letsencrypt-ip여야 합니다."));
            if (cert == "letsencrypt-ip" && GetParameterDefault(yaml, "LetsEncryptTermsAccepted") != "true")
                issues.Add(new ValidationIssue("오류", "Parameters.LetsEncryptTermsAccepted", "Let’s Encrypt 모드를 사용하려면 이용약관 동의가 true여야 합니다."));

            if (yaml.IndexOf('\t') >= 0)
                issues.Add(new ValidationIssue("오류", "YAML", "YAML 들여쓰기에 Tab 문자가 있습니다. 공백만 사용하세요."));
            if (yaml.Contains("__RELEASE_VERSION__") || Regex.IsMatch(yaml, "(?<!0)0{40}(?!0)") || Regex.IsMatch(yaml, "(?<!0)0{64}(?!0)"))
                issues.Add(new ValidationIssue("오류", "릴리스 고정값", "원본 틀의 자리표시자가 남아 있습니다. 배포용 완성 템플릿을 사용하세요."));
            if (Regex.IsMatch(yaml, "\\b(?:AKIA|ASIA)[A-Z0-9]{16}\\b") || yaml.Contains("BEGIN PRIVATE KEY"))
                issues.Add(new ValidationIssue("오류", "Secret", "AWS Access Key 또는 개인키로 보이는 값이 있습니다. YAML에 인증정보를 넣지 마세요."));

            Required(yaml, "FromPort: 80", "Networking", "HTTP 80 포트", issues);
            Required(yaml, "FromPort: 443", "Networking", "HTTPS 443 포트", issues);
            Required(yaml, "CidrListAliases:", "Networking", "브라우저 SSH 제한", issues);
            Required(yaml, "lightsail-connect", "Networking", "Lightsail 브라우저 SSH 별칭", issues);
            Required(yaml, "actual_sha256=", "UserData", "bootstrap SHA-256 검증", issues);
            Required(yaml, "sudo /opt/qfieldcloud/bin/show-admin-credentials.sh", "Outputs", "관리자 계정 확인 안내", issues);

            int errors = 0;
            int warnings = 0;
            foreach (ValidationIssue issue in issues)
            {
                if (issue.Severity == "오류") errors++;
                if (issue.Severity == "경고") warnings++;
            }
            if (errors == 0)
                issues.Insert(0, new ValidationIssue("통과", "요약", "필수 구조 검사 통과. 경고 " + warnings + "개. 실제 AWS 배포 성공을 보증하지는 않습니다."));
            return issues;
        }

        private static void Required(string yaml, string token, string location, string label, List<ValidationIssue> issues)
        {
            if (!yaml.Contains(token)) issues.Add(new ValidationIssue("오류", location, label + "을 찾을 수 없습니다."));
        }

        public static bool HasErrors(List<ValidationIssue> issues)
        {
            foreach (ValidationIssue issue in issues) if (issue.Severity == "오류") return true;
            return false;
        }
    }

    internal sealed class DiagramPanel : Panel
    {
        private readonly bool installation;

        public DiagramPanel(bool installationMode)
        {
            installation = installationMode;
            DoubleBuffered = true;
            BackColor = Color.White;
            MinimumSize = new Size(700, 390);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            if (installation) DrawInstallation(e.Graphics); else DrawArchitecture(e.Graphics);
        }

        private void DrawArchitecture(Graphics g)
        {
            int w = ClientSize.Width;
            Rectangle server = new Rectangle(170, 40, Math.Max(500, w - 205), 300);
            using (Pen border = new Pen(Color.FromArgb(37, 99, 235), 3)) g.DrawRoundedRectangle(border, server, 18);
            using (Font title = new Font("Malgun Gothic", 12, FontStyle.Bold)) g.DrawString("Lightsail standalone node (항상 1대)", title, Brushes.Navy, server.X + 18, server.Y + 12);

            Rectangle client = new Rectangle(18, 120, 125, 60);
            Rectangle nginx = new Rectangle(server.X + 25, 105, 120, 62);
            Rectangle app = new Rectangle(server.X + 190, 105, 140, 62);
            Rectangle db = new Rectangle(server.X + 380, 78, 125, 58);
            Rectangle storage = new Rectangle(server.X + 380, 160, 125, 58);
            Rectangle worker = new Rectangle(server.X + 190, 245, 140, 58);
            Rectangle qgis = new Rectangle(server.X + 380, 245, 125, 58);
            DrawBox(g, client, "QField / Browser", Color.FromArgb(241, 245, 249));
            DrawBox(g, nginx, "Nginx\nHTTPS :443", Color.FromArgb(219, 234, 254));
            DrawBox(g, app, "QFieldCloud\nApp · API", Color.FromArgb(220, 252, 231));
            DrawBox(g, db, "PostgreSQL\n+ PostGIS", Color.FromArgb(254, 249, 195));
            DrawBox(g, storage, "RustFS\nobject storage", Color.FromArgb(254, 226, 226));
            DrawBox(g, worker, "Worker wrapper\n작업 대기열", Color.FromArgb(243, 232, 255));
            DrawBox(g, qgis, "임시 QGIS 3\n작업 container", Color.FromArgb(255, 237, 213));
            DrawArrow(g, RectRight(client), RectLeft(nginx), "Static IP");
            DrawArrow(g, RectRight(nginx), RectLeft(app), "proxy");
            DrawArrow(g, RectRight(app), RectLeft(db), "data");
            DrawArrow(g, RectRight(app), RectLeft(storage), "files");
            DrawArrow(g, new Point(app.X + app.Width / 2, app.Bottom), new Point(worker.X + worker.Width / 2, worker.Y), "job");
            DrawArrow(g, RectRight(worker), RectLeft(qgis), "Docker");
        }

        private void DrawInstallation(Graphics g)
        {
            string[] steps = new string[] {
                "1  ZIP 또는 EXE 다운로드",
                "2  GUI에서 설정 변경 · 검증",
                "3  새 template.yaml 저장",
                "4  AWS Console · Region 선택",
                "5  YAML 업로드 · 실패 보존 선택",
                "6  Lightsail · Static IP 생성",
                "7  bootstrap · Docker · QFieldCloud 설치",
                "8  health + QGIS worker 검사",
                "9  Outputs의 HttpsUrl 접속"
            };
            int columns = 3;
            int boxW = Math.Max(190, (ClientSize.Width - 80) / columns);
            int boxH = 66;
            for (int i = 0; i < steps.Length; i++)
            {
                int row = i / columns;
                int col = i % columns;
                if (row % 2 == 1) col = columns - 1 - col;
                Rectangle box = new Rectangle(22 + col * (boxW + 10), 25 + row * 105, boxW, boxH);
                DrawBox(g, box, steps[i], i < 3 ? Color.FromArgb(219, 234, 254) : (i < 6 ? Color.FromArgb(220, 252, 231) : Color.FromArgb(254, 249, 195)));
                if (i < steps.Length - 1)
                {
                    int nextRow = (i + 1) / columns;
                    int nextCol = (i + 1) % columns;
                    if (nextRow % 2 == 1) nextCol = columns - 1 - nextCol;
                    Rectangle next = new Rectangle(22 + nextCol * (boxW + 10), 25 + nextRow * 105, boxW, boxH);
                    if (row == nextRow)
                    {
                        if (next.X > box.X) DrawArrow(g, RectRight(box), RectLeft(next), "");
                        else DrawArrow(g, RectLeft(box), RectRight(next), "");
                    }
                    else DrawArrow(g, new Point(box.X + box.Width / 2, box.Bottom), new Point(next.X + next.Width / 2, next.Y), "");
                }
            }
        }

        private static Point RectLeft(Rectangle r) { return new Point(r.Left, r.Top + r.Height / 2); }
        private static Point RectRight(Rectangle r) { return new Point(r.Right, r.Top + r.Height / 2); }

        private static void DrawBox(Graphics g, Rectangle rectangle, string text, Color fill)
        {
            using (Brush brush = new SolidBrush(fill)) g.FillRoundedRectangle(brush, rectangle, 12);
            using (Pen pen = new Pen(Color.FromArgb(71, 85, 105), 1.5f)) g.DrawRoundedRectangle(pen, rectangle, 12);
            using (Font font = new Font("Malgun Gothic", 9.5f, FontStyle.Bold))
            using (StringFormat format = new StringFormat())
            {
                format.Alignment = StringAlignment.Center;
                format.LineAlignment = StringAlignment.Center;
                g.DrawString(text, font, Brushes.Black, rectangle, format);
            }
        }

        private static void DrawArrow(Graphics g, Point from, Point to, string label)
        {
            using (Pen pen = new Pen(Color.FromArgb(71, 85, 105), 2))
            {
                pen.CustomEndCap = new AdjustableArrowCap(5, 7);
                g.DrawLine(pen, from, to);
            }
            if (!String.IsNullOrEmpty(label))
            {
                using (Font font = new Font("Malgun Gothic", 8))
                    g.DrawString(label, font, Brushes.DimGray, (from.X + to.X) / 2 - 18, (from.Y + to.Y) / 2 - 17);
            }
        }
    }

    internal static class GraphicsExtensions
    {
        public static void DrawRoundedRectangle(this Graphics graphics, Pen pen, Rectangle bounds, int radius)
        {
            using (GraphicsPath path = Rounded(bounds, radius)) graphics.DrawPath(pen, path);
        }

        public static void FillRoundedRectangle(this Graphics graphics, Brush brush, Rectangle bounds, int radius)
        {
            using (GraphicsPath path = Rounded(bounds, radius)) graphics.FillPath(brush, path);
        }

        private static GraphicsPath Rounded(Rectangle bounds, int radius)
        {
            int d = radius * 2;
            GraphicsPath path = new GraphicsPath();
            path.AddArc(bounds.Left, bounds.Top, d, d, 180, 90);
            path.AddArc(bounds.Right - d, bounds.Top, d, d, 270, 90);
            path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
            path.AddArc(bounds.Left, bounds.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }
    }

    internal sealed class MainForm : Form
    {
        private readonly RichTextBox yamlEditor = new RichTextBox();
        private readonly TextBox regionBox = new TextBox();
        private readonly TextBox zoneBox = new TextBox();
        private readonly TextBox instanceBox = new TextBox();
        private readonly ComboBox bundleCombo = new ComboBox();
        private readonly TextBox customBundleBox = new TextBox();
        private readonly ComboBox blueprintCombo = new ComboBox();
        private readonly TextBox customBlueprintBox = new TextBox();
        private readonly ComboBox certificateCombo = new ComboBox();
        private readonly CheckBox termsCheck = new CheckBox();
        private readonly NumericUpDown waitMinutes = new NumericUpDown();
        private readonly NumericUpDown alarmThreshold = new NumericUpDown();
        private readonly Label costLabel = new Label();
        private readonly ListView validationList = new ListView();
        private readonly TabControl tabs = new TabControl();
        private readonly ToolStripStatusLabel statusLabel = new ToolStripStatusLabel();
        private string currentPath = String.Empty;
        private bool dirty;

        public MainForm()
        {
            Text = "QFieldCloud Standalone Template Editor v0.1.1";
            Width = 1220;
            Height = 850;
            MinimumSize = new Size(980, 720);
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Malgun Gothic", 9F);
            FormClosing += OnFormClosing;

            Controls.Add(BuildTabs());
            Controls.Add(BuildHeader());
            Controls.Add(BuildMenu());
            StatusStrip status = new StatusStrip();
            status.Items.Add(statusLabel);
            Controls.Add(status);
            MainMenuStrip = (MenuStrip)Controls[Controls.Count - 2];

            string initial = TemplateEngine.LoadEmbeddedTemplate();
            SetDocument(initial, "내장 검증본 v0.1.1", false);
        }

        public void RenderTestScreenshots(string outputDirectory)
        {
            Directory.CreateDirectory(outputDirectory);
            ShowInTaskbar = false;
            Opacity = 0;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-30000, -30000);
            Show();
            Application.DoEvents();
            int[] tabIndexes = new int[] { 0, 2, 3, 5 };
            string[] fileNames = new string[] { "settings.png", "architecture.png", "installation.png", "validation.png" };
            for (int i = 0; i < tabIndexes.Length; i++)
            {
                tabs.SelectedIndex = tabIndexes[i];
                PerformLayout();
                Application.DoEvents();
                using (Bitmap bitmap = new Bitmap(ClientSize.Width, ClientSize.Height))
                {
                    DrawToBitmap(bitmap, new Rectangle(Point.Empty, ClientSize));
                    bitmap.Save(Path.Combine(outputDirectory, fileNames[i]), System.Drawing.Imaging.ImageFormat.Png);
                }
            }
            dirty = false;
            Close();
        }

        private Control BuildHeader()
        {
            Panel header = new Panel();
            header.Dock = DockStyle.Top;
            header.Height = 82;
            header.BackColor = Color.FromArgb(15, 23, 42);
            Label title = new Label();
            title.Text = "QFieldCloud Standalone Template Editor";
            title.ForeColor = Color.White;
            title.Font = new Font("Malgun Gothic", 18, FontStyle.Bold);
            title.Location = new Point(20, 11);
            title.AutoSize = true;
            Label sub = new Label();
            sub.Text = "AWS에 접속하지 않고 CloudFormation YAML만 수정·검증·저장합니다.  AWS Access Key를 입력하지 마세요.";
            sub.ForeColor = Color.FromArgb(203, 213, 225);
            sub.Location = new Point(23, 50);
            sub.AutoSize = true;
            header.Controls.Add(title);
            header.Controls.Add(sub);
            return header;
        }

        private MenuStrip BuildMenu()
        {
            MenuStrip menu = new MenuStrip();
            ToolStripMenuItem file = new ToolStripMenuItem("파일(&F)");
            file.DropDownItems.Add("내장 검증본으로 초기화", null, delegate { ResetToEmbedded(); });
            file.DropDownItems.Add("YAML 열기...", null, delegate { OpenYaml(); });
            file.DropDownItems.Add(new ToolStripSeparator());
            file.DropDownItems.Add("저장", null, delegate { SaveYaml(false); });
            file.DropDownItems.Add("다른 이름으로 저장...", null, delegate { SaveYaml(true); });
            file.DropDownItems.Add(new ToolStripSeparator());
            file.DropDownItems.Add("종료", null, delegate { Close(); });
            ToolStripMenuItem tools = new ToolStripMenuItem("도구(&T)");
            tools.DropDownItems.Add("안내 설정을 YAML에 적용", null, delegate { ApplyGuided(); });
            tools.DropDownItems.Add("현재 YAML 검증", null, delegate { ValidateCurrent(true); });
            ToolStripMenuItem help = new ToolStripMenuItem("도움말(&H)");
            help.DropDownItems.Add("앱 정보", null, delegate { MessageBox.Show(this,
                "QFieldCloud Standalone Template Editor v0.1.1\n\n비공식 로컬 편집 도구입니다. AWS API를 호출하지 않으며 실제 배포 성공을 보증하지 않습니다.\n코드 서명이 없으므로 Windows SmartScreen 경고가 나타날 수 있습니다.",
                "앱 정보", MessageBoxButtons.OK, MessageBoxIcon.Information); });
            menu.Items.Add(file);
            menu.Items.Add(tools);
            menu.Items.Add(help);
            menu.Dock = DockStyle.Top;
            return menu;
        }

        private Control BuildTabs()
        {
            tabs.Dock = DockStyle.Fill;
            tabs.TabPages.Add(BuildSettingsTab());
            tabs.TabPages.Add(BuildYamlTab());
            tabs.TabPages.Add(BuildArchitectureTab());
            tabs.TabPages.Add(BuildInstallationTab());
            tabs.TabPages.Add(BuildReferenceTab());
            tabs.TabPages.Add(BuildValidationTab());
            return tabs;
        }

        private TabPage BuildSettingsTab()
        {
            TabPage page = new TabPage("1. 설정 편집");
            Panel scroll = new Panel();
            scroll.Dock = DockStyle.Fill;
            scroll.AutoScroll = true;
            TableLayoutPanel table = new TableLayoutPanel();
            table.AutoSize = true;
            table.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            table.ColumnCount = 3;
            table.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 220));
            table.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 430));
            table.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 420));
            table.Padding = new Padding(22);
            AddHeading(table, "안내형 설정", "자주 바꾸는 안전한 항목입니다. 적용 버튼을 눌러야 YAML에 반영됩니다.");
            AddRow(table, "AWS Region", regionBox, "기본: ap-northeast-2 (Seoul). 다른 Region은 Lightsail 상품과 Ubuntu blueprint 제공 여부를 배포 직전에 확인하세요.");
            AddRow(table, "Availability Zone", zoneBox, "예: ap-northeast-2a. 선택한 Region으로 시작해야 합니다.");
            AddRow(table, "인스턴스 이름", instanceBox, "3~64자의 영문·숫자·점·밑줄·하이픈. 기존 자원과 중복되면 안 됩니다.");

            bundleCombo.DropDownStyle = ComboBoxStyle.DropDownList;
            bundleCombo.Items.Add(new BundleOption("nano_3_0", "nano_3_0 · 0.5GB · 2 vCPU · 20GB · USD 5/월", 5, 0.5M));
            bundleCombo.Items.Add(new BundleOption("micro_3_0", "micro_3_0 · 1GB · 2 vCPU · 40GB · USD 7/월", 7, 1));
            bundleCombo.Items.Add(new BundleOption("small_3_0", "small_3_0 · 2GB · 2 vCPU · 60GB · USD 12/월", 12, 2));
            bundleCombo.Items.Add(new BundleOption("medium_3_0", "medium_3_0 · 4GB · 2 vCPU · 80GB · USD 24/월 (검증 기준)", 24, 4));
            bundleCombo.Items.Add(new BundleOption("large_3_0", "large_3_0 · 8GB · 2 vCPU · 160GB · USD 44/월", 44, 8));
            bundleCombo.Items.Add(new BundleOption("xlarge_3_0", "xlarge_3_0 · 16GB · 4 vCPU · 320GB · USD 84/월", 84, 16));
            bundleCombo.Items.Add(new BundleOption("2xlarge_3_0", "2xlarge_3_0 · 32GB · 8 vCPU · 640GB · USD 164/월", 164, 32));
            bundleCombo.Items.Add(new BundleOption("", "직접 Bundle ID 입력 (고급)", 0, 0));
            bundleCombo.SelectedIndexChanged += delegate { UpdateBundleUi(); };
            AddRow(table, "Lightsail 사양", bundleCombo, "가격은 2026-08-24 AWS 공식표 기준이며 세금·환율·초과 전송량은 별도입니다. 4GB 미만은 권장하지 않습니다.");
            customBundleBox.Enabled = false;
            AddRow(table, "직접 Bundle ID", customBundleBox, "AWS get-bundles에서 확인한 활성 ID만 사용하세요. 오타나 미지원 Region이면 생성이 실패합니다.");
            costLabel.AutoSize = true;
            costLabel.Font = new Font("Malgun Gothic", 10, FontStyle.Bold);
            costLabel.ForeColor = Color.DarkRed;
            AddRow(table, "예상 기본 비용", costLabel, "스택 생성 후 삭제할 때까지 비용이 발생할 수 있습니다.");

            blueprintCombo.DropDownStyle = ComboBoxStyle.DropDownList;
            blueprintCombo.Items.Add("ubuntu_24_04 (검증됨)");
            blueprintCombo.Items.Add("직접 Blueprint ID 입력 (고급)");
            blueprintCombo.SelectedIndexChanged += delegate { customBlueprintBox.Enabled = blueprintCombo.SelectedIndex == 1; };
            AddRow(table, "OS Blueprint", blueprintCombo, "설치 스크립트는 Ubuntu 24.04의 apt와 systemd를 전제로 합니다.");
            customBlueprintBox.Enabled = false;
            AddRow(table, "직접 Blueprint ID", customBlueprintBox, "다른 OS는 설치 실패 가능성이 매우 높습니다.");

            certificateCombo.DropDownStyle = ComboBoxStyle.DropDownList;
            certificateCombo.Items.Add("self-signed");
            certificateCombo.Items.Add("letsencrypt-ip");
            certificateCombo.SelectedIndexChanged += delegate { termsCheck.Enabled = certificateCombo.Text == "letsencrypt-ip"; };
            AddRow(table, "HTTPS 인증서", certificateCombo, "self-signed는 브라우저 경고가 보입니다. letsencrypt-ip는 공개 발급과 갱신 과정이 필요합니다.");
            termsCheck.Text = "Let’s Encrypt Subscriber Agreement에 동의함";
            termsCheck.AutoSize = true;
            AddRow(table, "이용약관 동의", termsCheck, "letsencrypt-ip를 선택한 경우에만 true로 설정하세요.");

            waitMinutes.Minimum = 132;
            waitMinutes.Maximum = 240;
            waitMinutes.Value = 150;
            AddRow(table, "설치 대기시간(분)", waitMinutes, "현재 설치기의 알려진 최대 작업시간 때문에 132분 미만은 허용하지 않습니다. 기본 150분.");
            alarmThreshold.Minimum = 1;
            alarmThreshold.Maximum = 10;
            alarmThreshold.Value = 1;
            AddRow(table, "상태 실패 Alarm 기준", alarmThreshold, "StatusCheckFailed 값이 이 기준 이상이면 Alarm 상태가 됩니다.");

            TextBox node = new TextBox();
            node.Text = "1 (standalone 고정)";
            node.ReadOnly = true;
            node.BackColor = Color.FromArgb(241, 245, 249);
            AddRow(table, "서버 node 수", node, "여러 node는 YAML 값 변경이 아니라 Load Balancer, 공유 RDS/PostGIS와 S3가 필요한 standard-aws 아키텍처입니다.");

            FlowLayoutPanel buttons = new FlowLayoutPanel();
            buttons.AutoSize = true;
            Button apply = MakeButton("설정을 YAML에 적용", Color.FromArgb(37, 99, 235));
            apply.Click += delegate { ApplyGuided(); };
            Button validate = MakeButton("적용 후 검증", Color.FromArgb(22, 163, 74));
            validate.Click += delegate { ApplyGuided(); ValidateCurrent(true); };
            Button reset = MakeButton("내장 검증본 복원", Color.FromArgb(100, 116, 139));
            reset.Click += delegate { ResetToEmbedded(); };
            buttons.Controls.Add(apply);
            buttons.Controls.Add(validate);
            buttons.Controls.Add(reset);
            table.RowCount++;
            table.Controls.Add(buttons, 1, table.RowCount - 1);
            table.SetColumnSpan(buttons, 2);
            scroll.Controls.Add(table);
            page.Controls.Add(scroll);
            return page;
        }

        private TabPage BuildYamlTab()
        {
            TabPage page = new TabPage("2. YAML 원문 (고급)");
            Panel tools = new Panel();
            tools.Dock = DockStyle.Top;
            tools.Height = 46;
            Button apply = MakeButton("안내 설정 적용", Color.FromArgb(37, 99, 235));
            apply.Location = new Point(10, 7);
            apply.Click += delegate { ApplyGuided(); };
            Button validate = MakeButton("현재 원문 검증", Color.FromArgb(22, 163, 74));
            validate.Location = new Point(170, 7);
            validate.Click += delegate { ValidateCurrent(true); };
            Button save = MakeButton("YAML 저장", Color.FromArgb(100, 116, 139));
            save.Location = new Point(330, 7);
            save.Click += delegate { SaveYaml(false); };
            Label warning = new Label();
            warning.Text = "고급 편집은 모든 내용을 바꿀 수 있지만, release commit·checksum·UserData를 바꾸면 설치가 실패하거나 공급망 검증이 깨질 수 있습니다.";
            warning.ForeColor = Color.DarkRed;
            warning.AutoSize = true;
            warning.Location = new Point(500, 14);
            tools.Controls.Add(apply);
            tools.Controls.Add(validate);
            tools.Controls.Add(save);
            tools.Controls.Add(warning);
            yamlEditor.Dock = DockStyle.Fill;
            yamlEditor.Font = new Font("Consolas", 10);
            yamlEditor.WordWrap = false;
            yamlEditor.AcceptsTab = true;
            yamlEditor.DetectUrls = false;
            yamlEditor.TextChanged += delegate { dirty = true; UpdateTitle(); };
            page.Controls.Add(yamlEditor);
            page.Controls.Add(tools);
            return page;
        }

        private TabPage BuildArchitectureTab()
        {
            TabPage page = new TabPage("3. Standalone 구조");
            SplitContainer split = new SplitContainer();
            split.Dock = DockStyle.Fill;
            split.Orientation = Orientation.Horizontal;
            split.SplitterDistance = 380;
            split.Panel1.Controls.Add(new DiagramPanel(false) { Dock = DockStyle.Fill });
            Control description = ReadOnlyText(
                "[전체 구조]\n\n" +
                "• CloudFormation은 Lightsail instance 1대, Static IP 1개, firewall 규칙과 상태 Alarm을 만듭니다.\n" +
                "• Nginx가 외부 HTTPS 요청을 받아 QFieldCloud App/API로 전달합니다.\n" +
                "• PostgreSQL/PostGIS는 QFieldCloud 운영 DB이며 기존 식물이력관리 DB와 완전히 별개입니다.\n" +
                "• RustFS는 같은 서버 디스크에 project와 attachment 파일을 저장하는 S3-compatible object storage입니다.\n" +
                "• Worker wrapper가 작업 queue를 읽고 임시 QGIS 3 container를 실행합니다.\n" +
                "• 모든 구성요소가 한 node에 있으므로 서버 장애 시 전체 서비스가 중단됩니다. 자동 backup과 snapshot은 없습니다.\n\n" +
                "[왜 node가 1로 고정인가]\n\n" +
                "standalone에서 node만 늘리면 각 node가 서로 다른 로컬 DB와 파일을 갖게 되어 데이터가 갈라집니다. 다중 node에는 Load Balancer, 공유 RDS PostgreSQL/PostGIS, 공유 S3, Secret 관리와 migration 전략이 필요합니다. 이것은 standard-aws라는 별도 배포 방식으로 설계해야 합니다.");
            split.Panel2.Controls.Add(description);
            page.Controls.Add(split);
            return page;
        }

        private TabPage BuildInstallationTab()
        {
            TabPage page = new TabPage("4. 전체 설치 과정");
            SplitContainer split = new SplitContainer();
            split.Dock = DockStyle.Fill;
            split.Orientation = Orientation.Horizontal;
            split.SplitterDistance = 350;
            split.Panel1.Controls.Add(new DiagramPanel(true) { Dock = DockStyle.Fill });
            split.Panel2.Controls.Add(ReadOnlyText(
                "1. GitHub에서 배포 ZIP 또는 이 EXE를 다운로드합니다. EXE는 코드 서명이 없어 SmartScreen 경고가 나타날 수 있습니다.\n" +
                "2. GUI에서 Region, Availability Zone, instance 이름, Lightsail bundle과 인증서 방식을 설정합니다.\n" +
                "3. 검증을 통과한 새 template.yaml을 저장합니다. 앱은 AWS에 접속하지 않습니다.\n" +
                "4. AWS Console에서 대상 Region을 선택하고 CloudFormation → Create stack → Upload a template file로 YAML을 올립니다.\n" +
                "5. Configure stack options → Stack failure options에서 Preserve successfully provisioned resources를 직접 선택합니다. 이 실행 옵션은 YAML이나 앱이 자동 선택할 수 없습니다.\n" +
                "6. Submit을 누르면 비용이 발생할 수 있습니다. CloudFormation이 Lightsail와 Static IP를 생성합니다.\n" +
                "7. UserData가 고정 commit의 bootstrap.sh를 내려받고 SHA-256이 맞는 경우에만 실행합니다.\n" +
                "8. Docker, QFieldCloud, PostgreSQL/PostGIS, RustFS, Nginx와 QGIS worker를 설치합니다.\n" +
                "9. service health check와 QGIS worker smoke test를 모두 통과해야 CloudFormation에 성공 신호를 보냅니다.\n" +
                "10. Stack 상태가 CREATE_COMPLETE가 되면 Outputs → HttpsUrl로 접속합니다. 실패한 경우 보존된 서버의 root 전용 진단 로그를 확인합니다.\n\n" +
                "삭제: CloudFormation에서 stack을 삭제하고 Lightsail instance와 분리된 Static IP가 남지 않았는지 확인합니다. 삭제된 데이터는 복구할 수 없습니다."));
            page.Controls.Add(split);
            return page;
        }

        private TabPage BuildReferenceTab()
        {
            TabPage page = new TabPage("5. 설정·YAML 설명");
            DataGridView grid = new DataGridView();
            grid.Dock = DockStyle.Fill;
            grid.ReadOnly = true;
            grid.AllowUserToAddRows = false;
            grid.AllowUserToDeleteRows = false;
            grid.RowHeadersVisible = false;
            grid.AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.AllCells;
            grid.DefaultCellStyle.WrapMode = DataGridViewTriState.True;
            grid.Columns.Add("Setting", "설정");
            grid.Columns.Add("Path", "YAML 위치");
            grid.Columns.Add("Meaning", "의미와 변경 영향");
            grid.Columns[0].Width = 180;
            grid.Columns[1].Width = 300;
            grid.Columns[2].AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill;
            AddReference(grid, "Region", "Parameters.DeploymentRegion", "AWS 지리적 Region. Console 오른쪽 위 Region과 반드시 같아야 합니다. 바꾸면 비용·서비스 가용성·법적 데이터 위치가 달라질 수 있습니다.");
            AddReference(grid, "Availability Zone", "Parameters.AvailabilityZone", "Region 내부 데이터센터 구역. Lightsail capacity가 부족하면 다른 알파벳 zone을 선택합니다.");
            AddReference(grid, "Instance name", "Parameters.InstanceName", "Lightsail instance의 실제 이름이며 Static IP 이름과 Alarm이 이 값을 따라갑니다.");
            AddReference(grid, "Bundle ID", "Resources.LightsailInstance.Properties.BundleId", "RAM, vCPU, SSD, 전송량과 월 상한 비용을 묶은 Lightsail plan ID입니다. 생성 후 변경은 이 도구가 지원하지 않습니다.");
            AddReference(grid, "Blueprint ID", "Resources.LightsailInstance.Properties.BlueprintId", "운영체제 image ID입니다. bootstrap은 ubuntu_24_04에서만 검증되었습니다.");
            AddReference(grid, "Certificate mode", "Parameters.CertificateMode", "self-signed 또는 letsencrypt-ip. 후자는 외부 CA 발급과 약관 동의가 필요합니다.");
            AddReference(grid, "Networking", "Resources.LightsailInstance.Properties.Networking", "80/443은 공개, 22는 lightsail-connect browser SSH로 제한합니다. 원문에서 완화하면 공격 표면이 커집니다.");
            AddReference(grid, "UserData", "Resources.LightsailInstance.Properties.UserData", "첫 부팅 launcher입니다. 고정 commit에서 bootstrap을 받고 SHA-256을 검증합니다. 전문 검토 없이 수정하지 마세요.");
            AddReference(grid, "WaitCondition", "Resources.BootstrapWaitCondition", "설치와 전체 검사가 끝날 때까지 CloudFormation이 기다리는 시간입니다.");
            AddReference(grid, "Alarm", "Resources.StatusCheckFailedAlarm", "Lightsail instance 상태 검사가 실패할 때 표시되는 기본 Alarm입니다. 연락처 전송은 구성하지 않습니다.");
            AddReference(grid, "Outputs", "Outputs", "접속 URL, 관리자 계정 확인 명령, 삭제 안내와 릴리스 검증값을 사용자에게 보여 줍니다. Secret을 출력하면 안 됩니다.");
            page.Controls.Add(grid);
            return page;
        }

        private TabPage BuildValidationTab()
        {
            TabPage page = new TabPage("6. 검증 결과");
            Panel top = new Panel();
            top.Dock = DockStyle.Top;
            top.Height = 52;
            Button validate = MakeButton("현재 YAML 다시 검증", Color.FromArgb(22, 163, 74));
            validate.Location = new Point(12, 9);
            validate.Click += delegate { ValidateCurrent(false); };
            Label note = new Label();
            note.Text = "이 검사는 구조·필수값·Secret 패턴을 확인합니다. AWS의 실제 availability와 CloudFormation server-side 검증은 업로드 시 별도로 확인해야 합니다.";
            note.Location = new Point(200, 16);
            note.AutoSize = true;
            top.Controls.Add(validate);
            top.Controls.Add(note);
            validationList.Dock = DockStyle.Fill;
            validationList.View = View.Details;
            validationList.FullRowSelect = true;
            validationList.GridLines = true;
            validationList.Columns.Add("결과", 90);
            validationList.Columns.Add("위치", 260);
            validationList.Columns.Add("설명", 750);
            page.Controls.Add(validationList);
            page.Controls.Add(top);
            return page;
        }

        private static Control ReadOnlyText(string text)
        {
            Panel host = new Panel();
            host.Dock = DockStyle.Fill;
            host.BackColor = Color.White;
            host.AutoScroll = true;
            Label label = new Label();
            label.BackColor = Color.White;
            label.Font = new Font("Malgun Gothic", 9.5f);
            label.Text = text;
            label.Location = new Point(16, 12);
            label.AutoSize = true;
            label.MaximumSize = new Size(1120, 0);
            host.Controls.Add(label);
            host.Resize += delegate { label.MaximumSize = new Size(Math.Max(300, host.ClientSize.Width - 36), 0); };
            return host;
        }

        private static void AddReference(DataGridView grid, string setting, string path, string meaning)
        {
            grid.Rows.Add(setting, path, meaning);
        }

        private static Button MakeButton(string text, Color color)
        {
            Button button = new Button();
            button.Text = text;
            button.AutoSize = true;
            button.Height = 32;
            button.Padding = new Padding(8, 2, 8, 2);
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = 0;
            button.BackColor = color;
            button.ForeColor = Color.White;
            button.Margin = new Padding(5);
            return button;
        }

        private static void AddHeading(TableLayoutPanel table, string title, string description)
        {
            int row = table.RowCount++;
            Label label = new Label();
            label.Text = title;
            label.Font = new Font("Malgun Gothic", 15, FontStyle.Bold);
            label.AutoSize = true;
            label.Margin = new Padding(3, 8, 3, 4);
            Label note = new Label();
            note.Text = description;
            note.AutoSize = true;
            note.ForeColor = Color.DimGray;
            note.Margin = new Padding(3, 16, 3, 4);
            table.Controls.Add(label, 0, row);
            table.Controls.Add(note, 1, row);
            table.SetColumnSpan(note, 2);
        }

        private static void AddRow(TableLayoutPanel table, string name, Control input, string help)
        {
            int row = table.RowCount++;
            Label label = new Label();
            label.Text = name;
            label.AutoSize = true;
            label.Font = new Font("Malgun Gothic", 9.5f, FontStyle.Bold);
            label.Margin = new Padding(3, 12, 3, 8);
            input.Width = 410;
            input.Margin = new Padding(3, 8, 3, 8);
            Label note = new Label();
            note.Text = help;
            note.AutoSize = true;
            note.MaximumSize = new Size(410, 0);
            note.ForeColor = Color.DimGray;
            note.Margin = new Padding(3, 10, 3, 8);
            table.Controls.Add(label, 0, row);
            table.Controls.Add(input, 1, row);
            table.Controls.Add(note, 2, row);
        }

        private void SetDocument(string yaml, string source, bool isDirty)
        {
            yamlEditor.Text = yaml;
            currentPath = source;
            dirty = isDirty;
            LoadSettingsFromYaml();
            ValidateCurrent(false);
            UpdateTitle();
            statusLabel.Text = "불러옴: " + source;
        }

        private void LoadSettingsFromYaml()
        {
            string yaml = yamlEditor.Text;
            regionBox.Text = TemplateEngine.GetParameterDefault(yaml, "DeploymentRegion");
            zoneBox.Text = TemplateEngine.GetParameterDefault(yaml, "AvailabilityZone");
            instanceBox.Text = TemplateEngine.GetParameterDefault(yaml, "InstanceName");
            SelectBundle(TemplateEngine.GetResourceProperty(yaml, "LightsailInstance", "BundleId"));
            string blueprint = TemplateEngine.GetResourceProperty(yaml, "LightsailInstance", "BlueprintId");
            if (blueprint == "ubuntu_24_04") blueprintCombo.SelectedIndex = 0;
            else { blueprintCombo.SelectedIndex = 1; customBlueprintBox.Text = blueprint; }
            string cert = TemplateEngine.GetParameterDefault(yaml, "CertificateMode");
            certificateCombo.SelectedItem = cert;
            if (certificateCombo.SelectedIndex < 0) certificateCombo.SelectedIndex = 0;
            termsCheck.Checked = TemplateEngine.GetParameterDefault(yaml, "LetsEncryptTermsAccepted") == "true";
            string timeout = TemplateEngine.GetResourceProperty(yaml, "BootstrapWaitCondition", "Timeout");
            int seconds;
            if (Int32.TryParse(timeout, out seconds)) waitMinutes.Value = Math.Min(waitMinutes.Maximum, Math.Max(waitMinutes.Minimum, seconds / 60));
            string threshold = TemplateEngine.GetResourceProperty(yaml, "StatusCheckFailedAlarm", "Threshold");
            int thresholdValue;
            if (Int32.TryParse(threshold, out thresholdValue)) alarmThreshold.Value = Math.Min(alarmThreshold.Maximum, Math.Max(alarmThreshold.Minimum, thresholdValue));
            UpdateBundleUi();
        }

        private void SelectBundle(string bundleId)
        {
            for (int i = 0; i < bundleCombo.Items.Count; i++)
            {
                BundleOption option = (BundleOption)bundleCombo.Items[i];
                if (option.Id == bundleId)
                {
                    bundleCombo.SelectedIndex = i;
                    return;
                }
            }
            bundleCombo.SelectedIndex = bundleCombo.Items.Count - 1;
            customBundleBox.Text = bundleId;
        }

        private void UpdateBundleUi()
        {
            if (bundleCombo.SelectedItem == null) return;
            BundleOption option = (BundleOption)bundleCombo.SelectedItem;
            customBundleBox.Enabled = String.IsNullOrEmpty(option.Id);
            if (option.MonthlyUsd > 0)
            {
                costLabel.Text = "최대 USD " + option.MonthlyUsd.ToString("0.##") + "/월 + 세금·환율·초과 사용량";
                costLabel.ForeColor = option.MemoryGb < 4 ? Color.DarkRed : Color.FromArgb(180, 83, 9);
            }
            else
            {
                costLabel.Text = "직접 입력한 Bundle의 현재 가격을 AWS에서 확인하세요.";
                costLabel.ForeColor = Color.DarkRed;
            }
        }

        private string SelectedBundleId()
        {
            BundleOption option = (BundleOption)bundleCombo.SelectedItem;
            return String.IsNullOrEmpty(option.Id) ? customBundleBox.Text.Trim() : option.Id;
        }

        private string SelectedBlueprintId()
        {
            return blueprintCombo.SelectedIndex == 0 ? "ubuntu_24_04" : customBlueprintBox.Text.Trim();
        }

        private void ApplyGuided()
        {
            try
            {
                yamlEditor.Text = TemplateEngine.ApplyGuidedSettings(
                    yamlEditor.Text,
                    regionBox.Text.Trim(),
                    zoneBox.Text.Trim(),
                    instanceBox.Text.Trim(),
                    SelectedBlueprintId(),
                    SelectedBundleId(),
                    certificateCombo.Text,
                    termsCheck.Checked,
                    Decimal.ToInt32(waitMinutes.Value),
                    Decimal.ToInt32(alarmThreshold.Value));
                dirty = true;
                statusLabel.Text = "안내 설정을 YAML에 적용했습니다. 검증 후 저장하세요.";
                tabs.SelectedIndex = 1;
                UpdateTitle();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "설정 적용 실패", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private List<ValidationIssue> ValidateCurrent(bool switchTab)
        {
            List<ValidationIssue> issues = TemplateEngine.Validate(yamlEditor.Text);
            validationList.Items.Clear();
            foreach (ValidationIssue issue in issues)
            {
                ListViewItem item = new ListViewItem(issue.Severity);
                item.SubItems.Add(issue.Location);
                item.SubItems.Add(issue.Message);
                if (issue.Severity == "오류") item.BackColor = Color.MistyRose;
                else if (issue.Severity == "경고") item.BackColor = Color.LemonChiffon;
                else item.BackColor = Color.Honeydew;
                validationList.Items.Add(item);
            }
            bool errors = TemplateEngine.HasErrors(issues);
            statusLabel.Text = errors ? "검증 실패: 오류를 수정해야 저장할 수 있습니다." : "필수 구조 검사 통과. 실제 AWS 검증은 별도입니다.";
            if (switchTab) tabs.SelectedIndex = 5;
            return issues;
        }

        private void OpenYaml()
        {
            if (!ConfirmDiscard()) return;
            using (OpenFileDialog dialog = new OpenFileDialog())
            {
                dialog.Title = "CloudFormation YAML 열기";
                dialog.Filter = "YAML files (*.yaml;*.yml)|*.yaml;*.yml|All files (*.*)|*.*";
                if (dialog.ShowDialog(this) == DialogResult.OK)
                {
                    string yaml = File.ReadAllText(dialog.FileName, new UTF8Encoding(false));
                    SetDocument(yaml, dialog.FileName, false);
                }
            }
        }

        private void SaveYaml(bool saveAs)
        {
            List<ValidationIssue> issues = ValidateCurrent(false);
            if (TemplateEngine.HasErrors(issues))
            {
                tabs.SelectedIndex = 5;
                MessageBox.Show(this, "오류가 있는 YAML은 저장하지 않습니다. 검증 결과를 먼저 수정하세요.", "저장 중단", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            bool hasWarnings = false;
            foreach (ValidationIssue issue in issues) if (issue.Severity == "경고") hasWarnings = true;
            if (hasWarnings && MessageBox.Show(this, "경고가 남아 있습니다. 그래도 YAML을 저장하시겠습니까?", "경고 확인", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;

            string path = currentPath;
            if (saveAs || String.IsNullOrEmpty(path) || path.StartsWith("내장 ", StringComparison.Ordinal))
            {
                using (SaveFileDialog dialog = new SaveFileDialog())
                {
                    dialog.Title = "수정한 CloudFormation YAML 저장";
                    dialog.Filter = "YAML file (*.yaml)|*.yaml";
                    dialog.FileName = "qfieldcloud-custom-template.yaml";
                    if (dialog.ShowDialog(this) != DialogResult.OK) return;
                    path = dialog.FileName;
                }
            }
            File.WriteAllText(path, yamlEditor.Text, new UTF8Encoding(false));
            currentPath = path;
            dirty = false;
            statusLabel.Text = "저장 완료: " + path;
            UpdateTitle();
        }

        private void ResetToEmbedded()
        {
            if (!ConfirmDiscard()) return;
            SetDocument(TemplateEngine.LoadEmbeddedTemplate(), "내장 검증본 v0.1.1", false);
        }

        private bool ConfirmDiscard()
        {
            if (!dirty) return true;
            return MessageBox.Show(this, "저장하지 않은 변경을 버리시겠습니까?", "변경 확인", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) == DialogResult.Yes;
        }

        private void OnFormClosing(object sender, FormClosingEventArgs e)
        {
            if (!ConfirmDiscard()) e.Cancel = true;
        }

        private void UpdateTitle()
        {
            Text = "QFieldCloud Standalone Template Editor v0.1.1" + (dirty ? " *" : "") + " — " + currentPath;
        }
    }
}
