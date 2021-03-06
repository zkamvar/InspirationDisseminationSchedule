#' # Setup
#' 
#' This script will parse the data to help with construction of the schedule
#' for Inspiration Dissemination. It will gather in responses from a google
#' form, scheduled guests from a google sheet, and create dossiers and an
#' interactive visualization to help schedule guests without having to sift
#' through columns of a spreadsheet, emails, or separate files.
#'
#' ## Installing the 'scheduler' package
#' 
#' Some helper functions are defined in the package scheduler, which is part
#' of this repository. It exists on github and will install all the 
#' dependencies needed to make this script run.
#'
if (!"InspirationDisseminationSchedule" %in% installed.packages()[, "Package"]){
    if (!require("devtools") || packageVersion("devtools") < package_version("1.10.0")){
        install.packages("devtools", repos = "http://cran.r-project.org")
    }
    devtools::install_github("zkamvar/InspirationDisseminationSchedule")
}
#' 
#' Now all the packages need to be loaded
library("scheduler")
library("dplyr")
library("lubridate")
library("reshape2")
library("ggplot2")
library("ggvis")
library("googlesheets")
#' Sun Aug  9 18:38:57 2015 ------------------------------
#' Note:
#' 
#' Switching to a new system using googlesheets The first time you use this
#' script, a window will open where you will select the account you want 
#' associated with google sheets (choose Inspiration Dissemination). After that,
#' your authorization will be written to a file and you will never be asked
#' again.
#' 
#' Reading in the data
#' -------------------
#' 
#' Using two internal data holders, this allows the main data, IDS and scheduled
#' to be safely read even if the user replaces them in his or her global
#' environment.
#' 
#' ### Globals
#' 
#' These are variables for use throughout the script
HELLNO <- FALSE
options(stringsAsFactors = HELLNO)
any_given_sunday <- get_last_sunday() + dweeks(0:52) # Projecting out to one year
sundays          <- length(any_given_sunday)
category_names   <- list(
  Timestamp = "Timestamp", 
  Name      = "Name", 
  Email     = "Email", 
  Dept      = "Department.Program", 
  PI        = "Primary.Investigator.and.or.Major.Advisor.s.", 
  Deg       = "Degree.working.towards", 
  Avail     = "What.Sundays.are.you.available.", 
  Pref      = "Which.Sunday.is.your.preferred.date.", 
  Desc      = "Please.give.a.short..2.3.sentence..description.of.your.research"
)
#' ### Data
#' 
#' This will read in the data and save it in the global variables for
#' the scheduler package.
#' 
#' The google seet we are using at the moment is called "participants" and it
#' has 9 columns corresponding to the "category_names". If this is ever to 
#' change, the category_names variable and this section should change.
#' 
gs_title("participants") %>% # register the google sheet called "participants"
  gs_read() %>%              # read it in as a data frame
  setNames(names(.) %>% make.names()) %>%         # 'fix' names
  rename_(.dots = category_names) %>%             # set the names
  mutate(Pref = parse_date_time(Pref, "mdy")) %>% # recode preference as POSIX
  mutate(Name = make.unique(Name)) %>%            # ensure names are unique.
  (IDS$set)                         # store in the IDS internal data holder.
#' 
#' The procedure is similar here, except we are reading in the data for the 
#' guests that have already been scheduled.
all_guests_ss <- gs_title("scheduled_guests") 
all_guests_ss %>% 
  gs_read() %>% 
  mutate(Date = parse_date_time(Date, c("md", "mdy"))) %>%
  (scheduled$set)
#' 
#' Since it's nice to have the CSV of previous guests available for quick 
#' reference, here we are:
#' - sorting the incoming spreadsheet
#' - making the date a character string
#' - Adding the Department by left-joining the columns from the input data set
#' - Selecting only the columns entitled Name, Date, Dept, and Hosts

sched_out <- scheduled$get() %>% 
  `[`(order(.$Date), ) %>%                                 # Sort table by date
  mutate(Date = make_my_day(Date)) %>%                     # Convert date to character
  full_join(IDS$get(), by = "Name") %>%                    # Join the scheduled guests to get their department if it doesn't exist
  filter(!is.na(Date)) %>%                                 # Remove unscheduled guests
  mutate(Dept = ifelse(is.na(Dept.x), Dept.y, Dept.x)) %>% # Add the department of scheduled guests who don't have them.
  select(Name, Date, Showtime, Dept, Hosts) # Returning only Name, Date, Showtime, Dept, and Hosts
#' 
#' In order to make sure everything is up to date, we will write the filtered 
#' sheet to the drive, but before we do that, we should make sure that all the
#' variables we are choosing are the same and that the date is in string format
#' to avoid comparing datetimes, which is known to be problematic.
unfiltered_sched <- scheduled$get() %>% 
  select(Name, Date, Showtime, Dept, Hosts) %>% # choose only these columns
  mutate(Date = make_my_day(Date))              # make sure the date is in string format
#'
#' Now we check to see if our filtered schedule and unfiltered are different. If
#' they are, then the old backup sheet is deleted and the new one is replaced.
if (!identical(sched_out, unfiltered_sched)){
  # Remove old backup
  backup_title <- "scheduled_guests_backup"
  if (backup_title %in% gs_ls()$sheet_title){
    gs_delete(gs_title(backup_title))
  }
  # Backup current sheet
  gs_copy(all_guests_ss, backup_title)
  # Replace values
  gs_edit_cells(all_guests_ss, input = sched_out)
}
#'
#' Once all the checking and backups have been made, we can write this to a csv
#' file hosted on the github. 
# Write to github csv file.
write.table(sched_out, 
            file = "scheduled.csv", 
            sep = ",", 
            row.names = FALSE,
            col.names = TRUE)
#' Parsing the availability for the guests requires the creation of a separate
#' vector for each guest containing POSIX dates. Since each guest can have a
#' different number of availabilities, this should be a list.
avail_list <- lapply(IDS$get("Avail"), get_availability) %>%
  setNames(IDS$get("Name"))
#' Creating a 3 dimensional array to store the values.
#' 
#' The rows will be the dates and columns will be the guests. The third
#' dimension will contain indicators of their availability, their preference,
#' and whether or not the slot has been filled.
avail_array <- array(dim = c(sundays, length(avail_list), 3), 
                     dimnames = list(Sundays = as.character(any_given_sunday),
                                     Guest   = names(avail_list),
                                     c("Available", "Preference", "Filled")))
#'
#' Analysis
#' --------
#' 
#' ### Filling the array

# Creating logical vectors
is_available  <- vapply(avail_list, save_the_date, logical(sundays), any_given_sunday)
is_preference <- vapply(IDS$get("Pref"), save_the_date, logical(sundays), any_given_sunday)

# Guest Availability
avail_array[, , "Available"]  <- ifelse(is_available, "Available", "Unavailable")

# Guest preference
avail_array[, , "Preference"] <- ifelse(is_preference, "Preference", NA)

# Scheduled slots
## These will only be the slots that have dates AND names assigned.
future_dates <- as.character(scheduled$get("Date")) %in% rownames(avail_array)
scheduled_dates <- scheduled$get() %>% 
  filter(future_dates & !is.na(Name)) %>% # Filtering for only scheduled slots
  mutate(Date = as.character(Date)) %>%   # Mutating to character for comparisons
  select(Date) %>% unlist()               # Retrieving the dates
  
Sched_Sunday <- rownames(avail_array) %in% scheduled_dates
avail_array[Sched_Sunday, , "Filled"] <- "Scheduled"

# Removing the rows that are in the past.
avail_array <- avail_array[as_date(any_given_sunday) > ymd(Sys.Date()), , , drop = FALSE]

# Who still needs to be scheduled?
unscheduled <- !dimnames(avail_array)$Guest %in% scheduled$get("Name")
#'
#' Graphs
#' ---------
#' 
#' Now that we have all of our data, we can create data frames to use for
#' plotting in ggplot2. This will create a pdf that can be shared.

# step 1: create the data frames for each layer.
availdf      <- melt(avail_array[, unscheduled, "Available", drop = FALSE])
preferencedf <- melt(avail_array[, unscheduled, "Preference", drop = FALSE])
scheduledf   <- melt(avail_array[, unscheduled, "Filled", drop = FALSE])


avail_plot <- 
  ggplot(availdf, aes(x = Sundays, y = Guest, fill = value)) + 
  geom_tile() +
  geom_tile(aes(x = Sundays, y = Guest, fill = value, 
                alpha = ifelse(is.na(value), 0, 1)), 
            data = preferencedf) + 
  geom_tile(aes(x = Sundays, y = Guest, fill = value, 
                alpha = ifelse(is.na(value), 0, 0.75)), 
            data = scheduledf) +
  theme_classic() + 
  scale_alpha(guide = FALSE) +
  theme(axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5)) +
  scale_fill_manual(name = "Availability", 
                    labels = c("Available", "Unavailable", "Preference", "Scheduled"),
                    breaks = c("Available", "Unavailable", "Preference", "Scheduled"),
                    values = c(Preference = "#D7191C", Available = "#FDAE61", 
                               Scheduled = "grey25", Unavailable = "#2C7BB6")) +
  scale_y_discrete(expand = c(0, 0)) +
  scale_x_discrete(expand = c(0, 0))
ggsave(filename = "availability.pdf", width = 11, height = 5.5)
#'
#' Since it becomes difficult to look at the above plot when there are a large
#' number of participants, I realized it was better to display this using ggvis
#' so that, if run interactively, it could have a tooltip so you can hover over
#' a tile and see its date and if the guest is available.

# properties to make the x axis a little prettier
xax <- axis_props(labels = list(angle = -90, baseline = "middle", align = "right"))

vis_plot <- avail_array[, unscheduled , -3, drop = FALSE] %>%
  apply(1:2, compare_array) %>% # compare the availability hierarchy
  t %>%                         # transpose the result
  melt %>%                      # melt into a data frame
  group_by(Guest) %>%           # Add a scheduled column for opacity values
  mutate(Scheduled = ifelse(is.na(avail_array[, unique(Guest), 3]), 1, 0.5)) %>%
  ggvis(x = ~Sundays, y = ~Guest, fill = ~value, opacity := ~Scheduled) %>%
  layer_rects(width = band(), height = band()) %>%
  add_tooltip(html = infohover, "hover") %>% 
  add_tooltip(html = infoclick, "click") %>% 
  add_axis("x", title = "", properties = xax) %>%
  add_axis("y", title = "")

vis_plot # show the plot
#' Cleanup
#' -------
#' Now, we write out all the information we gathered and create the dossiers
#' so that we can take a look at them later.

# availablility table in text form
outmat <- t(apply(avail_array, 1:2, compare_array))
write.table(x = outmat, file = "availability.csv", sep = ",", col.names = NA)

# Writing the dossiers in markdown
for (i in names(avail_list)){
  fname <- make_filename(i, wd = ".", newdir = "/dossiers/md_files/")
  if (!file.exists(fname)){
    make_dossier(i, IDS$get(), avail_list, wd = ".")
  }
}

# processing the dossiers with pandoc
system("cd dossiers; make all")
