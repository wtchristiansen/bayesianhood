# Install necessary packages
install.packages(c("quantmod", "tidyverse", "brms", "caret", "future", "doFuture", "ggplot2", "extrafont", "mgcv", "ggthemes"))

# Load libraries
library(quantmod)
library(tidyverse)
library(brms)
library(caret)
library(future)
library(doFuture)
library(ggplot2)
library(extrafont) 
library(mgcv)
library(ggthemes)


# Set up parallel processing
plan(multisession, workers = 8) # Adjust 'workers' based on your machine's cores
registerDoFuture()

# get data

symbol <- "TSHA"
start_date <- Sys.Date() - 365*1 # Last x years
end_date <- Sys.Date()

# use quantmod package to get data

getSymbols(Symbols = symbol, src = "yahoo", from = start_date, to = end_date)
stock_data <- get(symbol)

# Dynamically create the column name to access the adjust prices
open_col_name <- paste0(symbol, ".Adjusted")

# Access the Open price column dynamically
stock_data$Price <- stock_data[, open_col_name]

# prep data

data <- stock_data %>% 
  as.data.frame() %>%
  mutate(Date = row.names(.)) %>%
  select(Date, Price) %>%
  na.omit() # Simple example, consider more sophisticated preprocessing

data$log_Price <- log(stock_data$Price)

# Split data
set.seed(123)
trainingIndex <- createDataPartition(data$log_Price, p = .8, list = FALSE, times = 1)
train_data <- data[trainingIndex,]
test_data <- data[-trainingIndex,]

# Ensure 'Date' columns are Date objects
train_data$Date <- as.Date(train_data$Date)
test_data$Date <- as.Date(test_data$Date)
data$Date <- as.Date(data$Date) # Ensuring this is also correctly set

# Now, subtract the minimum date from the dataset to create a TimeIndex
data$TimeIndex <- as.numeric(data$Date - min(data$Date))
train_data$TimeIndex <- as.numeric(train_data$Date - min(data$Date))
test_data$TimeIndex <- as.numeric(test_data$Date - min(data$Date))
test_data$TimeIndex <- as.numeric(test_data$Date - min(train_data$Date))


# specify formula, smoothing and autoregressive component
formula <- bf(log_Price ~ s(TimeIndex) + ar(TimeIndex, p = 1, cov = TRUE) + (1|TimeIndex))

# Define the Bayesian model using brms
# Fit the Bayesian model
bayesian_model <- brm(formula, 
                      data = train_data, 
                      family = gaussian(),
                      chains = 2, 
                      iter = 5000, 
                      warmup = 1000,
                      cores = 8,
                      seed = 123)

# Check summary
summary(bayesian_model)

#generate predictions posterior
posterior_samples <- posterior_predict(bayesian_model, newdata = test_data, allow_new_levels = TRUE)

predictions <- as.data.frame(predictions <- predict(bayesian_model, newdata = test_data, re_formula = NA))

# Exponentiate posterior samples to get them on the original scale
exp_posterior_samples <- exp(posterior_samples)

# Calculate credible intervals on the original scale
cred_int_lower <- apply(exp_posterior_samples, 2, quantile, probs = 0.025)
cred_int_upper <- apply(exp_posterior_samples, 2, quantile, probs = 0.975)

# Add to test_data on the original scale
test_data$CI_Lower <- cred_int_lower
test_data$CI_Upper <- cred_int_upper
test_data$Predicted <- exp(predictions$Estimate)

## generate predictions for future

# Assume the last TimeIndex in your data is max_time_index
max_time_index <- max(train_data$TimeIndex)

# Create a future time frame (e.g., next 30 days)
future_time_index <- seq(from = max_time_index + 1, by = 1, length.out = 30)

# Create a new data frame for prediction
future_data <- data.frame(TimeIndex = future_time_index)

## Predict future values
future_predictions <- as.data.frame(future_predictions <- predict(bayesian_model, newdata = future_data, re_formula = NA))


# Assuming future_predictions contains the log-scaled predictions
# and you've correctly extracted them into future_predictions$PredictedPrice

# Correctly assign predictions back to future_data
future_predictions$PredictedPrice <- as.numeric(future_predictions$Estimate)
future_data$PredictedPrice <- exp(as.numeric(future_predictions$PredictedPrice))

# Exponentiate future predictions to get them on the original scale
future_data$PredictedPrice <- exp(future_data$PredictedPrice)

# If the model outputs distributions, calculate means or medians as point predictions
future_data$PredictedPrice <- future_predictions$Estimate
future_data$StdError <- future_predictions$Est.Error

# convert time index into days from today
future_data$Days = future_data$TimeIndex - 365

# Calculate lower and upper credible intervals based on StdError, assuming a 95% CI for demonstration
# This is an approximation; adjust according to your specific method of CI calculation
future_data$lower_CI <- future_data$PredictedPrice - (1.96 * future_data$StdError)
future_data$upper_CI <- future_data$PredictedPrice + (1.96 * future_data$StdError)


# Plotting

max_price_day <- test_data[which.max(test_data$Price),]
min_price_day <- test_data[which.min(test_data$Price),]

# graph historical data with model predictions

ggplot(test_data, aes(x = Date)) + 
  geom_line(aes(y = Price), color = 'blue') +  # Actual values
  geom_line(aes(y = Predicted), color = 'red') +  # Predicted values
  geom_ribbon(aes(ymin = CI_Lower, ymax = CI_Upper), fill = 'orange', alpha = 0.2) +  # Credible intervals
  labs(title = paste("Predicted vs Actual Price for Past Year:", symbol), x = "Date", y = "Price") +
  geom_text(data = max_price_day, aes(x = Date, y = Price + 0.1, label = paste("Max:", sprintf("%.4f", Price))), vjust = -0.8, hjust = .9) +
  geom_text(data = min_price_day, aes(x = Date, y = Price - 0.1, label = paste("Min:", sprintf("%.4f", Price))), vjust = 1, hjust = -.02) +
  theme_economist()

# Find the day with the maximum predicted price
max_price_day_pred <- future_data[which.max(future_data$PredictedPrice),]
min_price_day_pred <- future_data[which.min(future_data$PredictedPrice),]


# Full Plot


ggplot(future_data, aes(x = Days)) +
  geom_line(aes(y = PredictedPrice), color = "red") +
  geom_ribbon(aes(ymin = lower_CI, ymax = upper_CI), fill = 'green', alpha = 0.2) +
  labs(title = paste("Predicted Price over Next Month:", symbol), x = "Days from Now", y = "Price") +
  theme_economist() +
  geom_vline(xintercept = 14, linetype="dashed", color = "blue") +
  geom_vline(xintercept = 7, linetype="dashed", color = "blue") +
  geom_text(data = max_price_day_pred, aes(x = Days, y = PredictedPrice + 0.1, label = paste("Max:", sprintf("%.4f", PredictedPrice))), vjust = -0.8, hjust = .9) +
  geom_text(data = min_price_day_pred, aes(x = Days, y = PredictedPrice - 0.1, label = paste("Min:", sprintf("%.4f", PredictedPrice))), vjust = 1, hjust = -.02) +
  scale_x_continuous(breaks = 0:30) + # X-axis labels for every day
  scale_y_continuous(breaks = function(x) seq(floor(min(x, na.rm = TRUE)), ceiling(max(x, na.rm = TRUE)), by = 1), limits = c(-3, max(future_data$PredictedPrice) * 4)) + # Adjusting y-scale and limits here
  theme(axis.text.x = element_text(vjust = 0.5, angle = 45)) +
  annotate("text", x = 14, y = mean(future_data$PredictedPrice, na.rm = TRUE), label = "2 Wks", hjust = -0.1, vjust = -0.65) + 
  annotate("text", x = 7, y = mean(future_data$PredictedPrice, na.rm = TRUE), label = "1 Wk", hjust = -0.1, vjust = -0.65) 
 



