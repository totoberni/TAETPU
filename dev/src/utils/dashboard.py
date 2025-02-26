import json
import os
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
from datetime import datetime
import numpy as np
from rich.console import Console
from rich.table import Table

console = Console()

class MonitoringDashboard:
    """Generate visualization dashboards from collected metrics"""
    
    def __init__(self, logs_dir="logs"):
        self.logs_dir = logs_dir
        self.metrics = {}
        self.tpu_metrics = {}
        self.experiments = []
    
    def load_experiment(self, experiment_id):
        """Load data from a specific experiment"""
        exp_dir = os.path.join(self.logs_dir, experiment_id)
        
        if not os.path.exists(exp_dir):
            console.print(f"[red]Experiment directory not found: {exp_dir}[/red]")
            return False
        
        # Load metrics history
        metrics_file = os.path.join(exp_dir, 'metrics_history.json')
        if os.path.exists(metrics_file):
            with open(metrics_file, 'r') as f:
                metrics_data = json.load(f)
                self.metrics[experiment_id] = pd.json_normalize(metrics_data)
        
        # Load TPU metrics if available
        tpu_metrics_dir = os.path.join(exp_dir, 'tpu_metrics')
        if os.path.exists(tpu_metrics_dir):
            tpu_files = [f for f in os.listdir(tpu_metrics_dir) if f.endswith('.json')]
            if tpu_files:
                latest_file = sorted(tpu_files)[-1]
                with open(os.path.join(tpu_metrics_dir, latest_file), 'r') as f:
                    self.tpu_metrics[experiment_id] = pd.json_normalize(json.load(f))
        
        self.experiments.append(experiment_id)
        console.print(f"[green]Loaded experiment: {experiment_id}[/green]")
        return True
    
    def load_all_experiments(self):
        """Load all experiments from logs directory"""
        if not os.path.exists(self.logs_dir):
            console.print(f"[red]Logs directory not found: {self.logs_dir}[/red]")
            return
        
        # Find all experiment directories
        exp_dirs = [d for d in os.listdir(self.logs_dir) 
                   if os.path.isdir(os.path.join(self.logs_dir, d))
                   and d not in ('tensorboard', 'profiler', 'tpu_metrics')]
        
        for exp_id in exp_dirs:
            self.load_experiment(exp_id)
    
    def print_experiment_summary(self):
        """Print summary of loaded experiments"""
        if not self.experiments:
            console.print("[yellow]No experiments loaded[/yellow]")
            return
        
        table = Table(title="Loaded Experiments")
        table.add_column("Experiment ID", style="cyan")
        table.add_column("Training Steps", style="green")
        table.add_column("Start Time", style="magenta")
        table.add_column("End Time", style="magenta")
        table.add_column("Duration", style="blue")
        
        for exp_id in self.experiments:
            if exp_id in self.metrics:
                df = self.metrics[exp_id]
                steps = str(df['step'].max()) if 'step' in df.columns else "N/A"
                
                if 'timestamp' in df.columns:
                    try:
                        start_time = pd.to_datetime(df['timestamp'].min())
                        end_time = pd.to_datetime(df['timestamp'].max())
                        duration = end_time - start_time
                        start_str = start_time.strftime('%Y-%m-%d %H:%M:%S')
                        end_str = end_time.strftime('%Y-%m-%d %H:%M:%S')
                        duration_str = str(duration)
                    except:
                        start_str, end_str, duration_str = "N/A", "N/A", "N/A"
                else:
                    start_str, end_str, duration_str = "N/A", "N/A", "N/A"
                
                table.add_row(exp_id, steps, start_str, end_str, duration_str)
            else:
                table.add_row(exp_id, "N/A", "N/A", "N/A", "N/A")
        
        console.print(table)
    
    def plot_training_metrics(self, metric_names=None, save_path=None):
        """Plot training metrics for all loaded experiments"""
        if not self.metrics:
            console.print("[yellow]No metrics data available[/yellow]")
            return
        
        # Determine metrics to plot
        all_metrics = set()
        for exp_id, df in self.metrics.items():
            all_metrics.update([col for col in df.columns 
                              if col not in ('step', 'timestamp')])
        
        if metric_names:
            metrics_to_plot = [m for m in metric_names if m in all_metrics]
        else:
            # Default to training metrics if available
            train_metrics = [m for m in all_metrics if m.startswith('train/')]
            if train_metrics:
                metrics_to_plot = train_metrics
            else:
                metrics_to_plot = list(all_metrics)[:5]  # Limit to first 5
        
        if not metrics_to_plot:
            console.print("[yellow]No matching metrics found to plot[/yellow]")
            return
        
        # Create plots
        for metric in metrics_to_plot:
            plt.figure(figsize=(10, 6))
            for exp_id, df in self.metrics.items():
                if metric in df.columns:
                    plt.plot(df['step'], df[metric], label=exp_id)
            
            plt.title(f"Training Metric: {metric}")
            plt.xlabel("Step")
            plt.ylabel(metric)
            plt.legend()
            plt.grid(True, alpha=0.3)
            
            if save_path:
                os.makedirs(save_path, exist_ok=True)
                plt.savefig(os.path.join(save_path, f"{metric.replace('/', '_')}.png"))
            else:
                plt.show()
            
            plt.close()
    
    def plot_tpu_metrics(self, metric_names=None, save_path=None):
        """Plot TPU performance metrics"""
        if not self.tpu_metrics:
            console.print("[yellow]No TPU metrics data available[/yellow]")
            return
        
        # Determine TPU metrics to plot
        all_metrics = set()
        for exp_id, df in self.tpu_metrics.items():
            numeric_cols = df.select_dtypes(include=[np.number]).columns
            all_metrics.update(numeric_cols)
        
        if metric_names:
            metrics_to_plot = [m for m in metric_names if m in all_metrics]
        else:
            # Default to important TPU metrics
            important_metrics = [
                'CompileTime', 'ExecuteTime', 'TPUTotalCompilationTime', 
                'TPUTotalExecutionTime', 'TPUUtilization'
            ]
            metrics_to_plot = [m for m in important_metrics if m in all_metrics]
            
            if not metrics_to_plot:
                metrics_to_plot = list(all_metrics)[:5]  # Limit to first 5
        
        if not metrics_to_plot:
            console.print("[yellow]No matching TPU metrics found to plot[/yellow]")
            return
        
        # Create plots
        for metric in metrics_to_plot:
            plt.figure(figsize=(10, 6))
            for exp_id, df in self.tpu_metrics.items():
                if metric in df.columns:
                    plt.plot(range(len(df)), df[metric], label=exp_id)
            
            plt.title(f"TPU Metric: {metric}")
            plt.xlabel("Measurement")
            plt.ylabel(metric)
            plt.legend()
            plt.grid(True, alpha=0.3)
            
            if save_path:
                os.makedirs(save_path, exist_ok=True)
                plt.savefig(os.path.join(save_path, f"tpu_{metric}.png"))
            else:
                plt.show()
            
            plt.close()
    
    def generate_report(self, output_dir="reports"):
        """Generate comprehensive HTML report with all metrics"""
        import matplotlib
        matplotlib.use('Agg')  # Non-interactive backend
        
        if not self.experiments:
            console.print("[yellow]No experiments loaded for report generation[/yellow]")
            return
        
        # Create output directory
        os.makedirs(output_dir, exist_ok=True)
        report_time = datetime.now().strftime('%Y%m%d_%H%M%S')
        report_dir = os.path.join(output_dir, f"report_{report_time}")
        os.makedirs(report_dir, exist_ok=True)
        
        # Generate plots
        plots_dir = os.path.join(report_dir, "plots")
        os.makedirs(plots_dir, exist_ok=True)
        
        console.print("[blue]Generating training metrics plots...[/blue]")
        self.plot_training_metrics(save_path=plots_dir)
        
        console.print("[blue]Generating TPU metrics plots...[/blue]")
        self.plot_tpu_metrics(save_path=plots_dir)
        
        # Generate HTML report
        html_file = os.path.join(report_dir, "report.html")
        console.print(f"[blue]Generating HTML report: {html_file}[/blue]")
        
        with open(html_file, 'w') as f:
            f.write(f"""<!DOCTYPE html>
<html>
<head>
    <title>TPU Experiment Report</title>
    <style>
        body {{ font-family: Arial, sans-serif; margin: 20px; }}
        h1, h2 {{ color: #333366; }}
        .experiment {{ margin-bottom: 30px; padding: 20px; border: 1px solid #ddd; border-radius: 5px; }}
        .metrics {{ display: flex; flex-wrap: wrap; }}
        .metric-card {{ width: 30%; margin: 10px; padding: 10px; border: 1px solid #eee; border-radius: 5px; }}
        .plot-section {{ margin: 20px 0; }}
        .plot-img {{ max-width: 100%; height: auto; margin: 10px 0; }}
        table {{ border-collapse: collapse; width: 100%; }}
        th, td {{ border: 1px solid #ddd; padding: 8px; text-align: left; }}
        th {{ background-color: #f2f2f2; }}
        tr:nth-child(even) {{ background-color: #f9f9f9; }}
    </style>
</head>
<body>
    <h1>TPU Experiment Report</h1>
    <p>Generated on: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
""")
            
            # Experiment summaries
            f.write("<h2>Experiment Summary</h2>\n")
            f.write("<table>\n")
            f.write("  <tr><th>Experiment ID</th><th>Training Steps</th><th>Start Time</th><th>End Time</th><th>Duration</th></tr>\n")
            
            for exp_id in self.experiments:
                if exp_id in self.metrics:
                    df = self.metrics[exp_id]
                    steps = str(df['step'].max()) if 'step' in df.columns else "N/A"
                    
                    if 'timestamp' in df.columns:
                        try:
                            start_time = pd.to_datetime(df['timestamp'].min())
                            end_time = pd.to_datetime(df['timestamp'].max())
                            duration = end_time - start_time
                            start_str = start_time.strftime('%Y-%m-%d %H:%M:%S')
                            end_str = end_time.strftime('%Y-%m-%d %H:%M:%S')
                            duration_str = str(duration)
                        except:
                            start_str, end_str, duration_str = "N/A", "N/A", "N/A"
                    else:
                        start_str, end_str, duration_str = "N/A", "N/A", "N/A"
                    
                    f.write(f"  <tr><td>{exp_id}</td><td>{steps}</td><td>{start_str}</td><td>{end_str}</td><td>{duration_str}</td></tr>\n")
                else:
                    f.write(f"  <tr><td>{exp_id}</td><td>N/A</td><td>N/A</td><td>N/A</td><td>N/A</td></tr>\n")
            
            f.write("</table>\n")
            
            # Training metrics plots
            f.write("<h2>Training Metrics</h2>\n")
            f.write("<div class='plot-section'>\n")
            
            train_plots = [p for p in os.listdir(plots_dir) if not p.startswith('tpu_')]
            for plot in train_plots:
                plot_path = f"plots/{plot}"
                f.write(f"  <div class='plot-container'>\n")
                f.write(f"    <h3>{plot.replace('.png', '').replace('_', '/')}</h3>\n")
                f.write(f"    <img class='plot-img' src='{plot_path}' alt='{plot}'>\n")
                f.write(f"  </div>\n")
            
            f.write("</div>\n")
            
            # TPU metrics plots
            f.write("<h2>TPU Performance Metrics</h2>\n")
            f.write("<div class='plot-section'>\n")
            
            tpu_plots = [p for p in os.listdir(plots_dir) if p.startswith('tpu_')]
            for plot in tpu_plots:
                plot_path = f"plots/{plot}"
                f.write(f"  <div class='plot-container'>\n")
                f.write(f"    <h3>{plot.replace('.png', '').replace('tpu_', '')}</h3>\n")
                f.write(f"    <img class='plot-img' src='{plot_path}' alt='{plot}'>\n")
                f.write(f"  </div>\n")
            
            f.write("</div>\n")
            
            f.write("</body>\n</html>")
        
        console.print(f"[green]Report generated successfully: {html_file}[/green]")
        return html_file

# Example usage
if __name__ == "__main__":
    # Create dashboard
    dashboard = MonitoringDashboard()
    
    # Load experiment data
    dashboard.load_all_experiments()
    
    # Print summary
    dashboard.print_experiment_summary()
    
    # Generate plots and report
    dashboard.generate_report() 