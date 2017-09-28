# INSIGHTS INSTALLER

This is a simple repository to automate the installation of the Insights CLI.

Eventually this may be just condensed into one of the Insights repositories,
or serve as a template for an RPM build script.

# To use:

Once you've checked this repository out, simply run the 'install.sh' script
with the name of the directory you want to put Insights into.  E.g.:

`sh install.sh $HOME/insights`

# Using Insights:

The installer sets Insights up in its own virtual Python environment.  To then
use Insights, you need to load that virtual environment again.

```
cd $HOME/insights
source bin/activate
```

This will then allow you to run the Insights collector.  You can
check this by issuing:

`insights-core/collect.py -p demo`
