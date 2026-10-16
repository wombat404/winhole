using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace PasswordRecovery;

public partial class Form1 : Form
{
    private const string DefaultPassword = "000000";

    private readonly string _workingDirectory =
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    private readonly ListBox _userListBox;
    private readonly TextBox _passwordTextBox;
    private readonly Button _setPasswordButton;

    public Form1()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

        Text = "Set User Password";
        Size = new Size(800, 500);
        StartPosition = FormStartPosition.CenterScreen;

        _userListBox = new ListBox
        {
            Dock = DockStyle.Fill,
            SelectionMode = SelectionMode.One,
            Font = new Font("Consolas", 10f),
            IntegralHeight = false
        };

        var bottomPanel = new Panel
        {
            Dock = DockStyle.Bottom,
            Height = 50,
            Padding = new Padding(8)
        };

        _passwordTextBox = new TextBox
        {
            Dock = DockStyle.Fill,
            Font = new Font("Segoe UI", 10f),
            PlaceholderText = "New password (empty = \"" + DefaultPassword + "\")"
        };

        _setPasswordButton = new Button
        {
            Dock = DockStyle.Right,
            Width = 140,
            Text = "Set Password"
        };
        _setPasswordButton.Click += SetPasswordButton_Click;

        bottomPanel.Controls.Add(_passwordTextBox);
        bottomPanel.Controls.Add(_setPasswordButton);

        Controls.Add(_userListBox);
        Controls.Add(bottomPanel);

        Load += (_, _) => LoadUserList();
    }

    private void LoadUserList()
    {
        _userListBox.Items.Clear();

        try
        {
            // Exit code is ignored on purpose: when the host has no resolvable
            // computer name, "net user" still prints the account list but exits
            // non-zero. The parsed body is the source of truth.
            var (_, output) = RunCmd("net", "user");

            var names = ParseUserNames(output);
            if (names.Count == 0)
            {
                ShowError("Could not read the user list:" + Environment.NewLine + output);
                return;
            }

            foreach (var name in names)
            {
                _userListBox.Items.Add(name);
            }
        }
        catch (Exception ex)
        {
            ShowError("Could not read the user list:" + Environment.NewLine + ex.Message);
        }
    }

    private static List<string> ParseUserNames(string output)
    {
        var lines = output.Replace("\r\n", "\n").Split('\n')
            .Select(l => l.TrimEnd())
            .ToList();

        int separator = lines.FindIndex(l => Regex.IsMatch(l, @"^-{3,}\s*$"));
        if (separator < 0)
        {
            return new List<string>();
        }

        var body = lines.Skip(separator + 1).ToList();

        while (body.Count > 0 && body[^1].Length == 0)
        {
            body.RemoveAt(body.Count - 1);
        }
        if (body.Count > 0)
        {
            // Drop the trailing "The command completed..." status line.
            body.RemoveAt(body.Count - 1);
        }

        var names = new List<string>();
        foreach (var line in body)
        {
            foreach (var part in Regex.Split(line, @"\s{2,}"))
            {
                var name = part.Trim();
                if (name.Length > 0)
                {
                    names.Add(name);
                }
            }
        }

        return names;
    }

    private (int ExitCode, string Output) RunCmd(params string[] args)
    {
        var encoding = Encoding.GetEncoding(850);

        var psi = new ProcessStartInfo
        {
            FileName = "cmd.exe",
            WorkingDirectory = _workingDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = encoding,
            StandardErrorEncoding = encoding
        };

        psi.ArgumentList.Add("/c");
        foreach (var arg in args)
        {
            psi.ArgumentList.Add(arg);
        }

        using var process = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start cmd.exe.");

        string stdout = process.StandardOutput.ReadToEnd();
        string stderr = process.StandardError.ReadToEnd();
        process.WaitForExit();

        return (process.ExitCode, stdout + stderr);
    }

    private void SetPasswordButton_Click(object? sender, EventArgs e)
    {
        if (_userListBox.SelectedItem is not string userName || userName.Length == 0)
        {
            MessageBox.Show(this, "Please select a user from the list first.",
                "No user selected", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        string newPassword = _passwordTextBox.Text.Trim();
        if (newPassword.Length == 0)
        {
            newPassword = DefaultPassword;
        }

        var confirm = MessageBox.Show(this,
            $"Set a new password for user \"{userName}\"?",
            "Confirm", MessageBoxButtons.OKCancel, MessageBoxIcon.Question);
        if (confirm != DialogResult.OK)
        {
            return;
        }

        try
        {
            var (exitCode, output) = RunCmd("net", "user", userName, newPassword);
            if (exitCode == 0)
            {
                _passwordTextBox.Clear();
                MessageBox.Show(this,
                    $"Password for \"{userName}\" was changed successfully.",
                    "Success", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            else
            {
                string message = string.IsNullOrWhiteSpace(output)
                    ? $"Exit code: {exitCode}"
                    : output.Trim();
                ShowError($"Could not change the password for \"{userName}\".{Environment.NewLine}{Environment.NewLine}{message}");
            }
        }
        catch (Exception ex)
        {
            ShowError($"Could not change the password for \"{userName}\".{Environment.NewLine}{Environment.NewLine}{ex.Message}");
        }
    }

    private void ShowError(string message)
    {
        MessageBox.Show(this, message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
